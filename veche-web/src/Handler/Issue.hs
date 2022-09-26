{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TemplateHaskell #-}

module Handler.Issue
    ( getIssueEditR
    , getIssueNewR
    , getIssueR
    , getIssuesR
    , postIssueR
    , postIssuesR
    , putIssueCloseR
    , putIssueReopenR
    , putIssueVoteR
    ) where

import Import

-- global
import Data.Map.Strict qualified as Map

-- component
import Model.Issue (IssueMaterialized (IssueMaterialized),
                    StateAction (Close, Reopen))
import Model.Issue qualified as Issue
import Model.StellarSigner qualified as StellarSigner
import Model.Vote qualified as Vote
import Templates.Comment (commentForestWidget, commentForm)
import Templates.Issue (closeReopenButton, editIssueForm, issueTable,
                        newIssueForm, voteButtons)
import Templates.User (userNameWidget)

import Genesis (mtlFund)

getIssueR :: IssueId -> Handler Html
getIssueR issueId = do
    IssueMaterialized
            { comments
            , body
            , isCloseReopenAllowed
            , isCommentAllowed
            , isEditAllowed
            , issue = Issue{issueTitle, issueOpen}
            , isVoteAllowed
            , requests
            , votes
            } <-
        Issue.load issueId

    signers <- StellarSigner.selectAll mtlFund
    let weights =
            Map.fromList
                [ (stellarSignerKey, stellarSignerWeight)
                | Entity _ signer <- signers
                , let StellarSigner{stellarSignerKey, stellarSignerWeight} =
                        signer
                ]
        voteResults =
            [ (choice, percentage, share, toList users)
            | (choice, users) <- Map.assocs votes
            , let
                choiceWeight =
                    sum
                        [ Map.findWithDefault 0 key weights
                        | User{userStellarAddress = key} <- toList users
                        ]
                percentage =
                    fromIntegral choiceWeight / fromIntegral (sum weights) * 100
                    :: Double
                share = show choiceWeight <> "/" <> show (sum weights)
            ]

    (commentFormFields, commentFormEnctype) <-
        generateFormPost $ commentForm (Just issueId) requests
    defaultLayout $(widgetFile "issue")

getIssueNewR :: Handler Html
getIssueNewR = do
    Entity _ User{userStellarAddress} <- requireAuth
    Entity signerId _ <-
        StellarSigner.getByAddress403 mtlFund userStellarAddress
    requireAuthz $ CreateIssue signerId
    formWidget <- generateFormPostB newIssueForm
    defaultLayout formWidget

getIssuesR :: Handler Html
getIssuesR = do
    mState <- lookupGetParam "state"
    let stateOpen = mState /= Just "closed"
    issues <- Issue.selectByOpen stateOpen
    (openIssueCount, closedIssueCount) <- Issue.countOpenAndClosed
    defaultLayout $(widgetFile "issues")

postIssuesR :: Handler Html
postIssuesR = do
    (result, formWidget) <- runFormPostB newIssueForm
    case result of
        FormSuccess content -> do
            issueId <- Issue.create content
            redirect $ IssueR issueId
        _ -> defaultLayout formWidget

putIssueVoteR :: IssueId -> Choice -> Handler ()
putIssueVoteR issueId choice = do
    Vote.record issueId choice
    hxRefresh

putIssueCloseR :: IssueId -> Handler ()
putIssueCloseR = closeReopen Close

putIssueReopenR :: IssueId -> Handler ()
putIssueReopenR = closeReopen Reopen

closeReopen :: StateAction -> IssueId -> Handler ()
closeReopen action issueId = do
    Issue.closeReopen issueId action
    hxRefresh

hxRefresh :: Handler ()
hxRefresh = addHeader "HX-Refresh" "true"

postIssueR :: IssueId -> Handler Html
postIssueR issueId = do
    (result, formWidget) <- runFormPostB $ editIssueForm issueId Nothing
    case result of
        FormSuccess content -> do
            Issue.edit issueId content
            redirect $ IssueR issueId
        _ -> defaultLayout formWidget

getIssueEditR :: IssueId -> Handler Html
getIssueEditR issueId = do
    content <- Issue.getContentForEdit issueId
    formWidget <- generateFormPostB $ editIssueForm issueId $ Just content
    defaultLayout formWidget
