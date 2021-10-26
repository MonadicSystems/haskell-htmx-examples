{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE InstanceSigs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}

module Main where

import Contravariant.Extras.Contrazip (contrazip3)
import Control.Monad.IO.Class (liftIO)
import Data.Functor.Identity (Identity)
import Data.Int
import Data.Functor.Contravariant
import Data.Profunctor
import Data.Proxy
import Data.Text
import Data.Tuple.Curry
import Data.Vector (Vector)
import GHC.Generics
import GHC.TypeLits
import Hasql.TH
import Hasql.Session (Session)
import Hasql.Statement (Statement(..))
import Lucid
import Lucid.HTMX
import Lucid.HTMX.Servant
import Network.Wai.Handler.Warp
import Prelude
import Servant.API
import Servant.HTML.Lucid
import Servant.Links
import Servant.Server

import qualified Data.Aeson as Aeson
import qualified Data.Text as Text
import qualified Data.Vector as Vector
import qualified Hasql.Session as Session
import qualified Hasql.Decoders as Decoders
import qualified Hasql.Encoders as Encoders
import qualified Hasql.Connection as Connection


-- COMMON STUFF START --

blankHtml :: Html ()
blankHtml = ""

baseHtml :: Monad m => Text -> HtmlT m a -> HtmlT m a
baseHtml title innerHtml = do
    doctype_

    html_ [lang_ "en"] ""

    head_ $ do
        meta_ [charset_ "utf-8"]
        meta_ [name_ "viewport", content_ "width=device-width, initial-scale=1"]

        title_ $ toHtml title

        link_ [href_ "https://unpkg.com/tailwindcss@^2/dist/tailwind.min.css", rel_ "stylesheet"]
        script_ [src_ "https://unpkg.com/htmx.org@1.5.0"] blankHtml
        script_ [src_ "https://unpkg.com/htmx.org/dist/ext/json-enc.js"] blankHtml

    body_ innerHtml

textStyle_ = classes_ ["text-xl", "text-semibold"]

buttonStyle_ color = classes_ ["px-4", "py-2", "bg-"<>color, "text-lg", "text-white", "rounded-md", "mt-5"]

-- COMMON STUFF END --

{- DATA MODEL START -}

newtype ID a = ID { unID :: Int32 }
    deriving (Eq, Show, FromHttpApiData, ToHttpApiData)
    deriving newtype (Aeson.FromJSON)

newtype Email = Email { unEmail :: Text }
    deriving (Eq, Show, ToHtml)
    deriving newtype (Aeson.FromJSON)

newtype Name = Name { unName :: Text }
    deriving (Eq, Show, ToHtml)
    deriving newtype (Aeson.FromJSON)

data Status = Active | Inactive deriving (Eq, Show, Read, Generic)

instance Aeson.FromJSON Status where

data Contact = Contact
    { contactID :: ID Contact
    , contactName :: Name
    , contactEmail :: Email
    , contactStatus :: Status
    }
    deriving (Eq, Show)

newtype ContactTable = ContactTable [Contact]

data ContactForm = ContactForm

data ContactFormData = ContactFormData
    { contactFormName :: Name
    , contactFormEmail :: Email
    , contactFormStatus :: Status
    }
    deriving (Eq, Generic, Show)

instance Aeson.FromJSON ContactForm where

{- DATA MODEL END -}

{- DATA API START -}

type GetContactTable = Get '[HTML] ContactTable

type GetContactForm = "edit" :> Capture "contact-id" (ID Contact) :> Get '[HTML] ContactForm

type GetContact = Capture "contact-id" (ID Contact) :> Get '[HTML] Contact

type PostContact = ReqBody '[JSON] ContactFormData :> Post '[HTML] Contact

type PatchContact = "edit" :> Capture "contact-id" (ID Contact) :> ReqBody '[JSON] ContactFormData :> Patch '[HTML] Contact

type DeleteContact = Capture "contact-id" (ID Contact) :> Delete '[HTML] NoContent

type API = GetContactTable
    :<|> GetContactForm
    :<|> GetContact
    :<|> PostContact
    :<|> PatchContact
    :<|> DeleteContact

contactTableEndpoint :: Proxy GetContactTable
contactTableEndpoint = Proxy

getContactEndpoint :: Proxy GetContact
getContactEndpoint = Proxy

deleteContactEndpoint :: Proxy DeleteContact
deleteContactEndpoint = Proxy

addContactEndpoint :: Proxy PostContact
addContactEndpoint = Proxy

editContactEndpoint :: Proxy PatchContact
editContactEndpoint = Proxy

editFormEndpoint :: Proxy GetContactForm
editFormEndpoint = Proxy

api :: Proxy API
api = Proxy

{- DATA API END -}

{- SQL QUERIES START -}

dropContactsSession :: Session ()
dropContactsSession = Session.sql
    [uncheckedSql|
        drop table if exists contacts
        |]

createContactsSession :: Session ()
createContactsSession = Session.sql
    [uncheckedSql|
        create table if not exists contacts (
            id serial primary key,
            name varchar (50) unique not null,
            email varchar (255) unique not null,
            status varchar (10) not null
        );
        |]

insertContactStatement :: Statement ContactForm Contact
insertContactStatement =
    dimap
        contactFormToTuple
        tupleToContact
        [singletonStatement|
            insert into contacts (name, email, status)
            values ($1 :: text, $2 :: text, $3 :: text)
            returning id :: int4, name :: text, email :: text, status :: text
        |]
    where
        contactFormToTuple :: ContactForm -> (Text, Text, Text)
        contactFormToTuple ContactForm{..} = (unName contactFormName, unEmail contactFormEmail, Text.pack . show $ contactFormStatus)

        tupleToContact :: (Int32, Text, Text, Text) -> Contact
        tupleToContact (id, name, email, status) = Contact
            { contactID = ID id
            , contactName = Name name
            , contactEmail = Email email
            , contactStatus = read . Text.unpack $ status
            }

insertContactsStatement :: Statement [ContactForm] ()
insertContactsStatement =
    dimap
        contactFormsUnzip
        id
        [resultlessStatement|
            insert into contacts (name, email, status)
            select * from unnest ($1 :: text[], $2 :: text[], $3 :: text[])
        |]
    where
        contactFormsUnzip :: [ContactForm] -> (Vector Text, Vector Text, Vector Text)
        contactFormsUnzip =
            Vector.unzip3
            . fmap
                (\ContactForm{..} ->
                    (unName contactFormName, unEmail contactFormEmail, Text.pack . show $ contactFormStatus)
                )
            . Vector.fromList

getContactStatement :: Statement (ID Contact) Contact
getContactStatement =
    dimap
        unID
        tupleToContact
        [singletonStatement|
            select id :: int4, name :: text, email :: text, status :: text
            from contacts
            where id = $1 :: int4
        |]
    where
        tupleToContact :: (Int32, Text, Text, Text) -> Contact
        tupleToContact (id, name, email, status) = Contact
            { contactID = ID id
            , contactName = Name name
            , contactEmail = Email email
            , contactStatus = read . Text.unpack $ status
            }

getContactsStatement :: Statement () [Contact]
getContactsStatement =
    dimap id (Vector.toList . fmap tupleToContact)
        [vectorStatement|
            select id :: int4, name :: text, email :: text, status :: text
            from contacts
            |]
    where
        tupleToContact :: (Int32, Text, Text, Text) -> Contact
        tupleToContact (id, name, email, status) = Contact
            { contactID = ID id
            , contactName = Name name
            , contactEmail = Email email
            , contactStatus = read . Text.unpack $ status
            }

deleteContactStatement :: Statement (ID Contact) ()
deleteContactStatement =
    dimap (\(ID contactID) -> contactID) id
        [resultlessStatement| 
            delete from contacts where id = $1 :: int4
            |]

updateContactStatement :: Statement (ID Contact, ContactForm) Contact
updateContactStatement =
    dimap
        contactFormWithIDToTuple
        tupleToContact
        [singletonStatement|
            update contacts
            set name = $2 :: Text,
                email = $3 :: Text,
                status = $4 :: Text
            where id = $1 :: int4
            returning id :: int4, name :: text, email :: text, status :: text
        |]
    where
        contactFormWithIDToTuple :: (ID Contact, ContactForm) -> (Int32, Text, Text, Text)
        contactFormWithIDToTuple (contactID, ContactForm{..}) =
            (unID contactID, unName contactFormName, unEmail contactFormEmail, Text.pack . show $ contactFormStatus)

        tupleToContact :: (Int32, Text, Text, Text) -> Contact
        tupleToContact (id, name, email, status) = Contact
            { contactID = ID id
            , contactName = Name name
            , contactEmail = Email email
            , contactStatus = read . Text.unpack $ status
            }

insertContactDB :: Connection.Connection -> ContactForm -> IO Contact
insertContactDB conn contactForm = do
    Right res <- Session.run (Session.statement contactForm insertContactStatement) conn
    pure res

insertContactsDB :: Connection.Connection -> [ContactForm] -> IO ()
insertContactsDB conn contacts = do
    Right res <- Session.run (Session.statement contacts insertContactsStatement) conn
    pure res

getContactFromDB :: Connection.Connection -> ID Contact -> IO Contact
getContactFromDB conn contactID = do
    Right res <- Session.run (Session.statement contactID getContactStatement) conn
    pure res

getContactsFromDB :: Connection.Connection -> IO [Contact]
getContactsFromDB conn = do
    Right res <- Session.run (Session.statement () getContactsStatement) conn
    pure res

deleteContactFromDB :: Connection.Connection -> ID Contact -> IO ()
deleteContactFromDB conn contactID = do
    Right res <- Session.run (Session.statement contactID deleteContactStatement) conn
    pure res

updateContactDB :: Connection.Connection -> (ID Contact, ContactForm) -> IO Contact
updateContactDB conn contactFormWithID = do
    Right res <- Session.run (Session.statement contactFormWithID updateContactStatement) conn
    pure res

{- SQL QUERIES END -}

{- HANDLERS START -}

contactTableHandler :: Connection.Connection -> Handler [Contact]
contactTableHandler conn = liftIO $ getContactsFromDB conn

getContactHandler :: Connection.Connection -> ID Contact -> Handler Contact
getContactHandler conn contactID = liftIO $ getContactFromDB conn contactID

addContactHandler :: Connection.Connection -> ContactForm -> Handler Contact
addContactHandler conn contactForm = do
    newContact <- liftIO $ insertContactDB conn contactForm
    pure newContact

deleteContactHandler :: Connection.Connection -> ID Contact -> Handler NoContent
deleteContactHandler conn contactID = do
  liftIO $ deleteContactFromDB conn contactID
  return NoContent

editContactHandler :: Connection.Connection -> ID Contact -> ContactForm -> Handler Contact
editContactHandler conn contactID contactForm = do
    editedContact <- liftIO $ updateContactDB conn (contactID, contactForm)
    return editedContact

editFormHandler :: Connection.Connection -> ID Contact -> Handler (HtmlT Identity ())
editFormHandler conn contactID = do
    contact <- liftIO $ getContactFromDB conn contactID
    pure $ editRow_ contact

server :: Connection.Connection -> Server (API (Identity ()))
server conn =
    contactTableHandler conn
    :<|> getContactHandler conn
    :<|> deleteContactHandler conn 
    :<|> addContactHandler conn
    :<|> editFormHandler conn
    :<|> editContactHandler conn

{- HANDLERS END -}

{- SAFE LINKS START -}

getContactLink :: ID Contact -> Link
getContactLink contactID = safeLink api getContactEndpoint $ contactID

deleteContactLink :: ID Contact -> Link
deleteContactLink contactID = safeLink api deleteContactEndpoint $ contactID

addContactLink :: Link
addContactLink = safeLink api addContactEndpoint

editContactLink :: ID Contact -> Link
editContactLink contactID = safeLink api editContactEndpoint $ contactID

editFormLink :: ID Contact -> Link
editFormLink contactID = safeLink api editFormEndpoint $ contactID

{- SAFE LINKS END -}

instance ToHtml (ID Contact) where
    toHtml = toHtml . show . unID
    toHtmlRaw = toHtml

instance ToHtml Status where
    toHtml = \case
        Active -> "Active"
        Inactive -> "Inactive"
    toHtmlRaw = toHtml

tableCellStyle_ color =
    class_ $ "border-4 border-blue-400 items-center justify-center px-4 py-2 bg-"<>color

tableButtonStyle_ color =
    classes_ ["px-4", "py-2", "bg-red-500", "text-lg", "text-white", "rounded-md", "bg-"<>color]

instance ToHtml Contact where
    toHtml Contact{..} = do
        let contactRowID = "contact-row-"<>(Text.pack . show $ unID contactID)
        tr_ [id_ contactRowID] $ do
            td_ [tableCellStyle_ "green-300", class_ " text-semibold text-lg text-center "] $ toHtml contactID
            td_ [tableCellStyle_ "green-300", class_ " text-semibold text-lg "] $ toHtml contactName
            td_ [tableCellStyle_ "green-300", class_ " text-semibold text-lg "] $ toHtml contactEmail
            td_ [tableCellStyle_ "green-300", class_ " text-semibold text-lg text-center "] $ toHtml contactStatus
            td_ [tableCellStyle_ "green-300", class_ " text-semibold text-lg "] $ do
                span_ [class_ "flex flex-row justify-center align-middle"] $ do
                    button_
                        [ tableButtonStyle_ "pink-400"
                        , class_ " mr-2 "
                        , hx_get_ $ editFormLink contactID
                        , hx_target_ $ "#"<>contactRowID
                        , hx_swap_ (HXSwapVal SwapPosOuter Nothing Nothing Nothing)
                        ] "Edit"
                    button_
                        [ tableButtonStyle_ "red-400"
                        , hx_delete_ $ deleteContactLink contactID
                        , hx_confirm_ "Are you sure?"
                        , hx_target_ $ "#"<>contactRowID
                        , hx_swap_ (HXSwapVal SwapPosOuter Nothing Nothing Nothing)
                        ]
                        "Delete"
    toHtmlRaw = toHtml

inputRow_ :: Monad m => HtmlT m ()
inputRow_ = do
    tr_ [id_ "add-contact-row"] $ do
        td_ [tableCellStyle_ "green-300"] ""
        td_ [tableCellStyle_ "green-300"] $ input_ [class_ "rounded-md px-2 add-contact-form-input", type_ "text", name_ "contactFormName"]
        td_ [tableCellStyle_ "green-300"] $ input_ [class_ "rounded-md px-2 add-contact-form-input", type_ "text", name_ "contactFormEmail"]
        td_ [tableCellStyle_ "green-300"] $ do
            form_ $ do
                span_ [class_ "flex flex-col justify-center align-middle"] $ do
                    label_ [] $ do
                        "Active"
                        input_
                            [ type_ "radio"
                            , name_ "contactFormStatus"
                            , value_ . Text.pack . show $ Active
                            , class_ " ml-2 add-contact-form-input "
                            ]
                    label_ [] $ do
                        "Inactive"
                        input_
                            [ type_ "radio"
                            , name_ "contactFormStatus"
                            , value_ . Text.pack . show $ Inactive
                            , class_ " ml-2 add-contact-form-input "
                            ]
        td_ [tableCellStyle_ "green-300"] $
            button_
                [ tableButtonStyle_ "purple-400"
                , class_ " w-full "
                , hx_ext_ (HXExtVal $ HashSet.fromList [JSONEnc])
                , hx_post_ addContactLink
                , hx_target_ "#add-contact-row"
                , hx_swap_ (HXSwapVal SwapPosBeforeBegin Nothing Nothing Nothing)
                , hx_include_ ".add-contact-form-input"
                ]
                "Add"

editRow_ :: Monad m => Contact -> HtmlT m ()
editRow_ Contact{..} = do
    let rowID = "edit-contact-row-"<>(Text.pack . show . unID $ contactID)
        inputClass = "edit-contact-form-" <> (Text.pack . show . unID $ contactID) <> "-input"

    tr_ [id_ rowID] $ do
        td_ [tableCellStyle_ "green-300", class_ " text-semibold text-lg text-center "] $ toHtml (Text.pack . show . unID $ contactID)
        td_ [tableCellStyle_ "green-300"] $ input_ [class_ $ "rounded-md px-2 " <> inputClass, type_ "text", name_ "contactFormName", value_ $ unName contactName]
        td_ [tableCellStyle_ "green-300"] $ input_ [class_ $ "rounded-md px-2 " <> inputClass, type_ "text", name_ "contactFormEmail", value_ $ unEmail contactEmail]
        td_ [tableCellStyle_ "green-300"] $ do
            form_ $ do
                span_ [class_ "flex flex-col justify-center align-middle"] $ do
                    label_ [] $ do
                        "Active"
                        input_
                            [ type_ "radio"
                            , name_ "contactFormStatus"
                            , value_ . Text.pack . show $ Active
                            , class_ $ " ml-2 " <> inputClass
                            , if (show contactStatus) == "Active" then checked_ else (class_ "")
                            ]
                    label_ [] $ do
                        "Inactive"
                        input_
                            [ type_ "radio"
                            , name_ "contactFormStatus"
                            , value_ . Text.pack . show $ Inactive
                            , class_ $ " ml-2 " <> inputClass
                            , if (show contactStatus) == "Inactive" then checked_ else (class_ "")
                            ]
        td_ [tableCellStyle_ "green-300"] $
            span_ [class_ "flex flex-row justify-center align-middle"] $ do
                button_
                    [ tableButtonStyle_ "green-500"
                    , class_ " mr-2 "
                    , hx_ext_ (HXExtVal $ HashSet.fromList [JSONEnc])
                    , hx_post_ $ editContactLink contactID
                    , hx_target_ $ "#"<>rowID
                    , hx_swap_ (HXSwapVal SwapPosOuter Nothing Nothing Nothing)
                    , hx_include_ $ "."<>inputClass
                    ]
                    "Save"
                button_
                    [ tableButtonStyle_ "red-500"
                    , hx_get_ $ getContactLink contactID
                    , hx_target_ $ "#"<>rowID
                    , hx_swap_ (HXSwapVal SwapPosOuter Nothing Nothing Nothing)
                    ]
                    "Cancel"

instance ToHtml [Contact] where
    toHtml contacts = baseHtml "Contact Table" $ do
        script_ "document.body.addEventListener('htmx:beforeSwap',function(e){'add-contact-row'===e.detail.target.id&&Array.from(document.getElementsByClassName('add-contact-form-input')).map(e=>{e.value&&(e.value=e.defaultValue),e.checked&&(e.checked=e.defaultChecked)})});"
        div_ [class_ "flex items-center justify-center h-screen"] $ do
            table_ [class_ "table-auto rounded-lg"] $ do
                thead_ [] $ do
                    tr_ [] $ do
                        th_ [tableCellStyle_ "yellow-200", class_ " text-lg "] "ID"
                        th_ [tableCellStyle_ "yellow-200", class_ " text-lg "] "Name"
                        th_ [tableCellStyle_ "yellow-200", class_ " text-lg "] "Email"
                        th_ [tableCellStyle_ "yellow-200", class_ " text-lg "] "Status"
                        th_ [tableCellStyle_ "yellow-200", class_ " text-lg "] "Action(s)"
                tbody_ $ do
                    (Prelude.mapM_ toHtml contacts)
                    inputRow_
    toHtmlRaw = toHtml

main :: IO ()
main = do
    let dbConnSettings = Connection.settings "localhost" 5432 "postgres" "dummy" "ex1"
        initialContacts =
            [ ContactForm (Name "Alice Jones") (Email "alice@gmail.com") Active
            , ContactForm (Name "Bob Hart") (Email "bhart@gmail.com") Inactive
            , ContactForm (Name "Corey Smith") (Email "coreysm@grubco.com") Active
            ]

    connResult <- Connection.acquire dbConnSettings
    case connResult of
        Left err -> print err
        Right conn -> do
            Session.run dropContactsSession conn
            Session.run createContactsSession conn
            insertContactsDB conn initialContacts

            let port = 8080
                application = serve @(API (Identity ())) Proxy $ server conn
            
            print $ "Serving application on port: " <> (show port)
            run port application

