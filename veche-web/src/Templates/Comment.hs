{-# LANGUAGE ApplicativeDo #-}
{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE DuplicateRecordFields #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE NoImplicitPrelude #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}

module Templates.Comment (
    commentAnchor,
    commentForm,
    commentForestWidget,
) where

import Import

-- global
import Data.Set qualified as Set
import Data.Time (rfc822DateFormat)
import Yesod.Form.Bootstrap3 (bfs)

-- component
import Model.Comment (Comment (Comment), CommentId, CommentInput (CommentInput),
                      CommentMaterialized (CommentMaterialized))
import Model.Comment qualified
import Model.Issue (IssueId)
import Model.Request (IssueRequestMaterialized (IssueRequestMaterialized))
import Model.Request qualified
import Templates.User (userNameText, userNameWidget)

commentForestWidget :: Forest CommentMaterialized -> Widget
commentForestWidget comments =
    [whamlet|
        <ul>
            $forall comment <- comments
                ^{commentWidget comment}
    |]

commentWidget :: Tree CommentMaterialized -> Widget
commentWidget
        (Node
            CommentMaterialized{id, author, comment, requestedUsers}
            subComments) =
    $(widgetFile "comment")
  where
    Entity _authorId commentAuthor = author
    Comment{message, type_, created} = comment
    createdTime = formatTime defaultTimeLocale rfc822DateFormat created

commentAnchor :: CommentId -> Text
commentAnchor id = "comment" <> toPathPiece id

commentForm ::
    Maybe IssueId ->
    [IssueRequestMaterialized] ->
    (Html -> MForm Handler (FormResult CommentInput, Widget))
commentForm mIssueId activeRequests =
    renderForm $ commentAForm mIssueId activeRequests

commentAForm ::
    Maybe IssueId -> [IssueRequestMaterialized] -> AForm Handler CommentInput
commentAForm mIssueId activeRequests = do
    issue <-
        areq
            hiddenField
            (bfs ("" :: Text)){fsName = Just "issue"}
            mIssueId
    message <-
        unTextarea <$>
        areq
            textareaField
            (bfs ("Comment" :: Text)){fsName = Just "message"}
            Nothing
    provideInfo <-
        aopt
            ( checkboxesFieldList'
                [ (requestLabel r, id)
                | r@IssueRequestMaterialized{id} <- activeRequests
                ]
            )
            (if null activeRequests then "" else "Provide info for")
                {fsName = Just "provide"}
            Nothing
    parent <-
        aopt hiddenField (bfs ("" :: Text)){fsName = Just "parent"} Nothing
    pure
        CommentInput
            { issue
            , message
            , requestUsers = Set.empty
            , provideInfo = maybe Set.empty Set.fromList provideInfo
            , parent
            }

requestLabel :: IssueRequestMaterialized -> Text
requestLabel IssueRequestMaterialized{requestor, comment} =
    userNameText user <> ": " <> message
  where
    Entity _ user = requestor
    Entity _ Comment{message} = comment

checkboxesFieldList' ::
    PathPiece a => [(Text, a)] -> Field (HandlerFor site) [a]
checkboxesFieldList' opts =
    Field{fieldParse, fieldView, fieldEnctype = UrlEncoded}
  where

    fieldParse optlist _ =
        pure
            case traverse fromPathPiece optlist of
                Nothing  -> Left "Error parsing values"
                Just res -> Right $ Just res

    fieldView _id name attrs _val _isReq =
        [whamlet|
            $forall (display, value) <- opts
                <div .checkbox>
                    <label>
                        <input type=checkbox name=#{name}
                            value=#{toPathPiece value} *{attrs}>
                        #{display}
        |]
