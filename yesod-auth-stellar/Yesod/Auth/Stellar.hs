{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DisambiguateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}

module Yesod.Auth.Stellar
    (
    -- * Auth plugin
      authStellar
    , Config (..)
    ) where

import Control.Exception (Exception, throwIO)
import Control.Monad (unless)
import Crypto.Nonce (nonce128urlT)
import Crypto.Nonce qualified
import Data.ByteString.Base64 (decodeBase64, encodeBase64)
import Data.Foldable (toList)
import Data.Function ((&))
import Data.Text (Text, strip)
import Data.Text qualified as Text
import Data.Text.Encoding (decodeUtf8', encodeUtf8)
import Network.HTTP.Client.TLS (newTlsManager)
import Network.HTTP.Types (Status (Status))
import Network.HTTP.Types qualified
import Network.ONCRPC.XDR (emptyBoundedLengthArray, lengthArray, unLengthArray,
                           xdrDeserialize, xdrSerialize)
import Network.Stellar.Builder (buildWithFee, tbMemo, tbOperations,
                                transactionBuilder, verify, viewAccount)
import Network.Stellar.Keypair (decodePublicKey, encodePublicKey)
import Network.Stellar.Network (publicNetwork, testNetwork)
import Network.Stellar.TransactionXdr (DataValue, ManageDataOp (ManageDataOp),
                                       Memo (Memo'MEMO_TEXT),
                                       Operation (Operation),
                                       OperationBody (OperationBody'MANAGE_DATA),
                                       Transaction (Transaction),
                                       TransactionEnvelope (TransactionEnvelope))
import Network.Stellar.TransactionXdr qualified
import Network.URI (escapeURIString, isReserved)
import Servant.Client (BaseUrl, ClientError (FailureResponse),
                       ResponseF (Response, responseStatusCode), mkClientEnv,
                       runClientM)
import System.IO.Unsafe (unsafePerformIO)
import Yesod.Auth (Auth, AuthHandler, AuthPlugin (AuthPlugin), Creds (Creds),
                   Route (PluginR), setCredsRedirect)
import Yesod.Auth qualified
import Yesod.Core (HandlerFor, HandlerSite, MonadHandler, RenderMessage,
                   TypedContent, WidgetFor, invalidArgs, liftHandler, liftIO,
                   logErrorS, lookupGetParam, notAuthenticated, whamlet)
import Yesod.Form (AForm, FormMessage, FormResult (FormSuccess), aopt, areq,
                   fsName, textField, textareaField, unTextarea)
import Yesod.Form qualified as Yesod
import Yesod.Form.Bootstrap3 (BootstrapFormLayout (BootstrapBasicForm), bfs,
                              renderBootstrap3)

-- project
import Stellar.Horizon.Client (getAccount)
import Stellar.Horizon.Types (Account (Account), Signer (Signer))
import Stellar.Horizon.Types qualified

pluginName :: Text
pluginName = "stellar"

pluginRoute :: Route Auth
pluginRoute = PluginR pluginName []

data Config app = Config
    { horizon :: BaseUrl
    , setVerifyKey :: Text -> Text -> WidgetFor app ()
    , checkAndRemoveVerifyKey :: Text -> Text -> HandlerFor app Bool
    }

-- | Flow:
-- 1. 'login' shows 'addressForm'.
-- 2. User enters address (public key).
-- 3. 'login' shows 'responseForm' with challenge (dummy transaction)
--    based on address.
-- 4. User signs the transaction and enters signed envelope to the form.
-- 5. 'dispatch' verifies the signature and assigns credentials.
authStellar :: RenderMessage app FormMessage => Config app -> AuthPlugin app
authStellar config =
    AuthPlugin
        { apName     = pluginName
        , apLogin    = login config
        , apDispatch = dispatch config
        }

type Method = Text

type Piece = Text

addressField :: Text
addressField = "stellar_address"

responseForm ::
    (RenderMessage site FormMessage, HandlerSite m ~ site, MonadHandler m) =>
    AForm m Text
responseForm =
    unTextarea <$>
    areq
        textareaField
        (bfs ("Paste the signed piece here:" :: Text)){fsName = Just "response"}
        Nothing

data VerificationData = VerificationData{address, nonce :: Text}

dispatch :: Config app -> Method -> [Piece] -> AuthHandler app TypedContent
dispatch config@Config{checkAndRemoveVerifyKey} _method _path = do
    ((result, _formWidget), _formEnctype) <- runFormPost responseForm
    case result of
        FormSuccess response -> do
            VerificationData{address, nonce} <- verifyResponse response
            verifyAccount config address
            ok <- liftHandler $ checkAndRemoveVerifyKey address nonce
            if ok then
                setCredsRedirect $ makeCreds address
            else
                invalidArgs ["Verification key is invalid or expired"]
        _ -> invalidArgs [Text.pack $ show result]

makeCreds :: Text -> Creds app
makeCreds credsIdent =
    Creds{credsPlugin = pluginName, credsIdent, credsExtra = []}

login ::
    RenderMessage app FormMessage =>
    Config app -> (Route Auth -> Route app) -> WidgetFor app ()
login Config{setVerifyKey} routeToMaster = do
    mAddress <- lookupGetParam addressField
    case mAddress of
        Nothing -> makeAddressForm
        Just address0 -> do
            let address = strip address0
            nonce <- nonce128urlT nonceGenerator
            setVerifyKey address nonce
            challenge <- makeChallenge address nonce
            makeResponseForm routeToMaster challenge

makeAddressForm :: RenderMessage app FormMessage => WidgetFor app ()
makeAddressForm = do
    (widget, enctype) <- generateFormGet addressForm
    [whamlet|
        <form method=get enctype=#{enctype}>
            ^{widget}
            <button type=submit .btn .btn-primary>Next
    |]

addressForm ::
    (RenderMessage site FormMessage, HandlerSite m ~ site, MonadHandler m) =>
    AForm m (Maybe Text)
addressForm =
    aopt
        textField
        (bfs ("Stellar public address (starts with G):" :: Text))
            {fsName = Just "stellar_address"}
        Nothing

makeResponseForm ::
    RenderMessage app FormMessage =>
    (Route Auth -> Route app) -> Text -> WidgetFor app ()
makeResponseForm routeToMaster challenge = do
    (widget, enctype) <- generateFormPost responseForm
    [whamlet|
        $newline never
        Sign this transaction, but do not submit it:
        <div>
            <code .stellar_challenge style="overflow-wrap: break-word;">
                #{challenge}
        <div>
            [
                <a href="https://laboratory.stellar.org/#xdr-viewer?input=#{challengeE}&type=TransactionEnvelope&network=public" target="_blank">
                    View in Lab
            ] [
                <a href="https://laboratory.stellar.org/#txsigner?xdr=#{challengeE}" target="_blank">
                    Sign in Lab
            ]
        <form method=post action=@{routeToMaster pluginRoute} enctype=#{enctype} id=auth_stellar_response_form>
            ^{widget}
            <button type=submit .btn .btn-primary>Log in
    |]
  where
    challengeE = escapeURIString (not . isReserved) $ Text.unpack challenge

data InternalError = InternalErrorNonceTooLong
    deriving (Exception, Show)

makeChallenge :: MonadHandler m => Text -> Text -> m Text
makeChallenge address nonce0 = do
    publicKey <- decodePublicKey address ?| invalidArgs ["Bad address"]
    nonce <- lengthArray (encodeUtf8 nonce0) ?| internalErrorNonceTooLong
    pure $ makeChallenge' publicKey nonce
  where

    m ?| e = maybe e pure m

    internalErrorNonceTooLong = liftIO $ throwIO InternalErrorNonceTooLong

    makeChallenge' publicKey nonce =
        (transactionBuilder publicKey 0)
            {tbMemo = Just loggingIntoVeche, tbOperations = [NonceOp nonce]}
        & buildWithFee 0
        & toEnvelope
        & xdrSerialize
        & encodeBase64

    toEnvelope tx = TransactionEnvelope tx emptyBoundedLengthArray

pattern NonceOp :: DataValue -> Operation
pattern NonceOp value =
    Operation
    { operation'sourceAccount = Nothing
    , operation'body =
        OperationBody'MANAGE_DATA (ManageDataOp "nonce" (Just value))
    }

loggingIntoVeche :: Memo
loggingIntoVeche = Memo'MEMO_TEXT "Logging into Veche"

verifyResponse :: MonadHandler m => Text -> m VerificationData
verifyResponse envelopeXdrBase64 = do
    envelope <- decodeEnvelope
    let TransactionEnvelope{transactionEnvelope'tx} = envelope
        Transaction
                { transaction'memo
                , transaction'operations
                , transaction'sourceAccount
                } =
            transactionEnvelope'tx
        account = viewAccount transaction'sourceAccount
    verifySignature account envelope
    verifyMemo transaction'memo
    nonce <- getNonce transaction'operations
    pure VerificationData{address = encodePublicKey account, nonce}
  where

    e ?| msg = either (const $ invalidArgs [msg]) pure e

    decodeEnvelope = do
        envelopeXdrRaw <-
            decodeBase64 (encodeUtf8 envelopeXdrBase64)
            ?| "Transaction envelope must be encoded as Base64"
        xdrDeserialize envelopeXdrRaw
            ?| "Transaction envelope must be encoded as XDR"

    verifySignature account (TransactionEnvelope tx signatures) = do
        signature <-
            case toList $ unLengthArray signatures of
                [signature] -> pure signature
                _ -> invalidArgs ["Expected exactly 1 signature"]
        let verified =
                or  [ verify network tx account signature
                    | network <- [publicNetwork, testNetwork]
                    ]
        unless verified $ invalidArgs ["Signature is not verified"]

    verifyMemo transaction'memo =
        unless (transaction'memo == loggingIntoVeche) $
            invalidArgs ["Bad memo"]

    getNonce transaction'operations =
        case toList $ unLengthArray transaction'operations of
            [NonceOp nonce] -> decodeUtf8' (unLengthArray nonce) ?| "Bad nonce"
            _ -> invalidArgs ["Bad operations"]

-- | Throws an exception on error
verifyAccount :: MonadHandler m => Config app -> Text -> m ()
verifyAccount Config{horizon} address = do
    account <- getAccount'
    assert "account must be personal" $ isPersonal account
  where

    getAccount' = do
        eResult <-
            liftIO do
                manager <- newTlsManager
                runClientM (getAccount address) $ mkClientEnv manager horizon
        case eResult of
            Left (FailureResponse _ Response{responseStatusCode})
                | Status{statusCode = 404} <- responseStatusCode ->
                    invalidArgs ["Account doesn't exist"]
            Left err -> liftIO $ throwIO err
            Right result -> pure result

    assert message condition
        | condition = pure ()
        | otherwise = do
            $logErrorS pluginName message
            notAuthenticated

    isPersonal Account{signers} =
        case signers of
            [Signer{key, weight}]   -> key == address && weight > 0
            _                       -> False

runFormPost ::
    (MonadHandler m, RenderMessage (HandlerSite m) FormMessage) =>
    AForm m a -> m ((FormResult a, WidgetFor (HandlerSite m) ()), Yesod.Enctype)
runFormPost = Yesod.runFormPost . renderBootstrap3 BootstrapBasicForm

generateFormGet ::
    MonadHandler m =>
    AForm m a -> m (WidgetFor (HandlerSite m) (), Yesod.Enctype)
generateFormGet = Yesod.generateFormGet' . renderBootstrap3 BootstrapBasicForm

generateFormPost ::
    (MonadHandler m, RenderMessage (HandlerSite m) FormMessage) =>
    AForm m a -> m (WidgetFor (HandlerSite m) (), Yesod.Enctype)
generateFormPost = Yesod.generateFormPost . renderBootstrap3 BootstrapBasicForm

nonceGenerator :: Crypto.Nonce.Generator
nonceGenerator = unsafePerformIO Crypto.Nonce.new
{-# NOINLINE nonceGenerator #-}
