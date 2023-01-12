module Hasql.ListenNotify
  ( -- * Listen

    -- ** Listen
    listen,
    unlisten,
    unlistenAll,

    -- ** Await
    Notification (..),
    await,
    poll,
    backendPid,

    -- * Notify
    Notify (..),
    notify,
  )
where

import Control.Exception (throwIO, try)
import Control.Monad.Except (throwError)
import Control.Monad.IO.Class
import Control.Monad.Reader (ask)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Builder as ByteString (Builder)
import qualified Data.ByteString.Builder as ByteString.Builder
import qualified Data.ByteString.Builder.Prim as ByteString.Builder.Prim
import qualified Data.ByteString.Lazy as ByteString.Lazy
import Data.Functor.Contravariant ((>$<))
import Data.Text (Text)
import qualified Data.Text.Encoding as Text
import Data.Word (Word8)
import qualified Database.PostgreSQL.LibPQ as LibPQ
import GHC.Conc.IO (threadWaitRead)
import GHC.Generics (Generic)
import qualified Hasql.Connection as Connection
import qualified Hasql.Decoders as Decoders
import qualified Hasql.Encoders as Encoders
import Hasql.Session (Session)
import qualified Hasql.Session as Session
import Hasql.Statement (Statement (..))
import System.Posix.Types (CPid)

-- | Listen to a channel.
--
-- https://www.postgresql.org/docs/current/sql-listen.html
listen :: Text -> Statement () ()
listen chan =
  Statement (builderToByteString sql) Encoders.noParams Decoders.noResult False
  where
    sql :: ByteString.Builder
    sql =
      "LISTEN \"" <> escapeIdentifier chan <> "\""

-- | Stop listening to a channel.
--
-- https://www.postgresql.org/docs/current/sql-unlisten.html
unlisten :: Text -> Statement () ()
unlisten chan =
  Statement (builderToByteString sql) Encoders.noParams Decoders.noResult False
  where
    sql :: ByteString.Builder
    sql =
      "UNLISTEN \"" <> escapeIdentifier chan <> "\""

-- | Stop listening to all channels.
--
-- https://www.postgresql.org/docs/current/sql-unlisten.html
unlistenAll :: Statement () ()
unlistenAll =
  Statement "UNLISTEN *" Encoders.noParams Decoders.noResult False

-- | An incoming notification.
data Notification = Notification
  { channel :: !Text,
    payload :: !Text,
    pid :: !CPid
  }
  deriving stock (Eq, Generic, Show)

-- | Get the next notification received from the server.
--
-- https://www.postgresql.org/docs/current/libpq-notify.html
await :: Session Notification
await =
  libpq (\conn -> try (await_ conn)) >>= \case
    Left err -> throwError err
    Right notification -> pure (parseNotification notification)

await_ :: LibPQ.Connection -> IO LibPQ.Notify
await_ conn =
  pollForNotification
  where
    pollForNotification :: IO LibPQ.Notify
    pollForNotification =
      poll_ conn >>= \case
        -- Block until a notification arrives. Snag: the connection might be closed (what). If so, attempt to reset it
        -- and poll for a notification on the new connection.
        Nothing ->
          LibPQ.socket conn >>= \case
            -- "No connection is currently open"
            Nothing -> do
              pqReset conn
              pollForNotification
            Just socket -> do
              threadWaitRead socket
              -- Data has appeared on the socket, but libPQ won't buffer it for us unless we do something (PQexec, etc).
              -- PQconsumeInput is provided for when we don't have anything to do except populate the notification
              -- buffer.
              pqConsumeInput conn
              pollForNotification
        Just notification -> pure notification

-- | Variant of 'await' that doesn't block.
poll :: Session (Maybe Notification)
poll =
  libpq (\conn -> try (poll_ conn)) >>= \case
    Left err -> throwError err
    Right maybeNotification -> pure (parseNotification <$> maybeNotification)

-- First call `notifies` to pop a notification off of the buffer, if there is one. If there isn't, try `consumeInput` to
-- populate the buffer, followed by another followed by another `notifies`.
poll_ :: LibPQ.Connection -> IO (Maybe LibPQ.Notify)
poll_ conn =
  LibPQ.notifies conn >>= \case
    Nothing -> do
      pqConsumeInput conn
      LibPQ.notifies conn
    notification -> pure notification

-- | Get the PID of the backend process handling this session. This can be used to filter out notifications that
-- originate from this session.
--
-- https://www.postgresql.org/docs/current/libpq-status.html
backendPid :: Session CPid
backendPid =
  libpq LibPQ.backendPID

-- | An outgoing notification.
data Notify = Notify
  { channel :: !Text,
    payload :: !Text
  }
  deriving stock (Eq, Generic, Show)

-- | Notify a channel.
--
-- https://www.postgresql.org/docs/current/sql-notify.html
notify :: Statement Notify ()
notify =
  Statement sql encoder Decoders.noResult True
  where
    sql :: ByteString
    sql =
      "SELECT pg_notify($1, $2)"

    encoder :: Encoders.Params Notify
    encoder =
      ((\Notify {channel} -> channel) >$< Encoders.param (Encoders.nonNullable Encoders.text))
        <> ((\Notify {payload} -> payload) >$< Encoders.param (Encoders.nonNullable Encoders.text))

------------------------------------------------------------------------------------------------------------------------
-- Little wrappers that throw

pqConsumeInput :: LibPQ.Connection -> IO ()
pqConsumeInput conn =
  LibPQ.consumeInput conn >>= \case
    False -> throwQueryError conn "PQconsumeInput()"
    True -> pure ()

pqReset :: LibPQ.Connection -> IO ()
pqReset conn = do
  LibPQ.reset conn
  LibPQ.status conn >>= \case
    LibPQ.ConnectionOk -> throwQueryError conn "PQreset()"
    _ -> pure ()

-- Throws a QueryError
throwQueryError :: LibPQ.Connection -> ByteString -> IO void
throwQueryError conn context = do
  message <- LibPQ.errorMessage conn
  throwIO (Session.QueryError context [] (Session.ClientError message))

--

libpq :: (LibPQ.Connection -> IO a) -> Session a
libpq action = do
  conn <- ask
  liftIO (Connection.withLibPQConnection conn action)

builderToByteString :: ByteString.Builder -> ByteString
builderToByteString =
  ByteString.Lazy.toStrict . ByteString.Builder.toLazyByteString
{-# INLINE builderToByteString #-}

-- Escape " as "", so e.g. `listen "foo\"bar"` will send the literal bytes: LISTEN "foo""bar"
escapeIdentifier :: Text -> ByteString.Builder
escapeIdentifier ident =
  Text.encodeUtf8BuilderEscaped escape ident
  where
    escape :: ByteString.Builder.Prim.BoundedPrim Word8
    escape =
      ByteString.Builder.Prim.condB
        (== 34) -- double-quote
        ( ByteString.Builder.Prim.liftFixedToBounded
            ( const ('"', '"')
                ByteString.Builder.Prim.>$< ByteString.Builder.Prim.char7
                  ByteString.Builder.Prim.>*< ByteString.Builder.Prim.char7
            )
        )
        (ByteString.Builder.Prim.liftFixedToBounded ByteString.Builder.Prim.word8)

-- Parse a Notify from a LibPQ.Notify
parseNotification :: LibPQ.Notify -> Notification
parseNotification notification =
  Notification
    { channel = Text.decodeUtf8 (LibPQ.notifyRelname notification),
      payload = Text.decodeUtf8 (LibPQ.notifyExtra notification),
      pid = LibPQ.notifyBePid notification
    }
