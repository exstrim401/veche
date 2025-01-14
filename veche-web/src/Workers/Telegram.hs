{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DisambiguateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE NumericUnderscores #-}
{-# LANGUAGE OverloadedStrings #-}

module Workers.Telegram (telegramBot) where

-- prelude
import Import hiding (filter, for_)
import Prelude (filter)

-- global
import Control.Concurrent (threadDelay)
import Data.Foldable (for_)
import Database.Persist.Sql (runSqlPool)
import Network.HTTP.Types (forbidden403)
import Servant.Client (ClientError (FailureResponse), ResponseF (Response))
import Servant.Client qualified
import System.Random (randomRIO)
import Text.Blaze.Html.Renderer.Text (renderHtml)
import Web.Telegram.API.Bot (ChatId (ChatId), ParseMode (HTML), TelegramClient,
                             Token (Token), message_parse_mode, sendMessageM,
                             sendMessageRequest)
import Web.Telegram.API.Bot qualified as Telegram

-- component
import Model.Event (SomeEvent (SomeEvent))
import Model.Event qualified as Event
import Model.Telegram (Telegram (Telegram))
import Model.Telegram qualified
import Model.User qualified as User

telegramBot :: App -> IO ()
telegramBot app = do
    putStrLn "Started Telegram bot"
    forever do
        events <- runDB Event.dbGetUndelivered
        for_ events deliver
        randomDelay

  where

    deliver :: SomeEvent -> IO ()
    deliver (SomeEvent eventE@(Entity id event)) = do
        users <- runDB $ Event.dbGetUsersToDeliver event
        notifyAll eventE $ filterWhitelist users
        runDB $ Event.dbSetDelivered id

    filterWhitelist
        | [] <- whitelist   = identity
        | otherwise         =
            filter \(_, Telegram{username}) -> username `elem` whitelist

    App{appConnPool, appSettings, appHttpManager} = app

    AppSettings
            {appTelegramBotToken, appTelegramBotNotifyWhitelist = whitelist} =
        appSettings

    randomDelay = do
        delaySeconds <- randomRIO (1, 10)
        threadDelay $ delaySeconds * 1_000_000

    runDB = (`runSqlPool` appConnPool)

    notifyAll event users =
        for_ users \(userId, telegram) -> do
            msg <- runDB $ Event.makeMessage app event
            result <-
                runTelegramClient' $ notify telegram $ toStrict $ renderHtml msg
            case result of
                Left (FailureResponse _ Response{responseStatusCode})
                    | responseStatusCode == forbidden403 ->
                        runDB $ User.dbDeleteTelegram userId
                Left e -> throwIO $ userError $ show (e, event, renderHtml msg)
                Right () -> pure ()

    runTelegramClient' =
        Telegram.runTelegramClient
            (Token $ "bot" <> appTelegramBotToken)
            appHttpManager

notify :: Telegram -> Text -> TelegramClient ()
notify Telegram{chatid} text =
    void $
    sendMessageM
        (sendMessageRequest (ChatId chatid) text)
            {message_parse_mode = Just HTML}
