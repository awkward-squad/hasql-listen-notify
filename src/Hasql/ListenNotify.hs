module Hasql.ListenNotify
  ( -- * Listen
    listen,
    unlisten,
    unlistenAll,

    -- * Notify
    Notification (..),
    notify,
    notifies,
    notifies',
  )
where

import Control.Monad.IO.Class
import Control.Monad.Reader (ask)
import Data.ByteString (ByteString)
import qualified Data.ByteString.Builder as ByteString.Builder
import qualified Data.ByteString.Builder.Prim as ByteString.Builder.Prim
import qualified Data.ByteString.Lazy as ByteString.Lazy
import Data.Text (Text)
import qualified Data.Text.Encoding as Text
import Data.Word (Word8)
import qualified Database.PostgreSQL.LibPQ as LibPQ
import GHC.Conc.IO (threadWaitRead)
import qualified Hasql.Connection as Connection
import qualified Hasql.Decoders as Decoders
import qualified Hasql.Encoders as Encoders
import Hasql.Session (Session)
import Hasql.Statement (Statement (..))

-- | @LISTEN@ to a channel.
--
-- https://www.postgresql.org/docs/current/sql-listen.html
listen :: Text -> Statement () ()
listen chan =
  Statement sql Encoders.noParams Decoders.noResult False
  where
    sql :: ByteString
    sql =
      builderToByteString ("LISTEN \"" <> escapeIdentifier chan <> "\"")

-- | @UNLISTEN@ to a channel.
--
-- https://www.postgresql.org/docs/current/sql-unlisten.html
unlisten :: Text -> Statement () ()
unlisten chan =
  Statement sql Encoders.noParams Decoders.noResult False
  where
    sql :: ByteString
    sql =
      builderToByteString ("UNLISTEN \"" <> escapeIdentifier chan <> "\"")

-- | @UNLISTEN *@.
--
-- https://www.postgresql.org/docs/current/sql-unlisten.html
unlistenAll :: Statement () ()
unlistenAll =
  Statement "UNLISTEN *" Encoders.noParams Decoders.noResult False

-- | A notification.
data Notification = Notification
  { channel :: !Text,
    payload :: !ByteString
  }

notify :: undefined
notify = undefined

-- | Get the next notification received from the server.
--
-- https://www.postgresql.org/docs/current/libpq-notify.html
notifies :: Session (Maybe Notification)
notifies =
  libpq \conn -> fmap parseNotification <$> LibPQ.notifies conn

-- | A variant of 'notifies' that blocks until a notification arrives.
notifies' :: Session Notification
notifies' =
  libpq \conn ->
    let loop =
          LibPQ.notifies conn >>= \case
            Nothing ->
              LibPQ.socket conn >>= \case
                Nothing -> undefined
                Just socket -> do
                  threadWaitRead socket
                  LibPQ.consumeInput conn >>= \case
                    False -> undefined
                    True -> loop
            Just notification -> pure (parseNotification notification)
     in loop

libpq :: (LibPQ.Connection -> IO a) -> Session a
libpq action = do
  conn <- ask
  liftIO (Connection.withLibPQConnection conn action)

--

builderToByteString :: ByteString.Builder.Builder -> ByteString
builderToByteString =
  ByteString.Lazy.toStrict . ByteString.Builder.toLazyByteString
{-# INLINE builderToByteString #-}

-- Escape " as "", so e.g. `listen "foo\"bar"` will send the literal bytes: LISTEN "foo""bar"
escapeIdentifier :: Text -> ByteString.Builder.Builder
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

-- Parse a Notification from a LibPQ.Notify
parseNotification :: LibPQ.Notify -> Notification
parseNotification notification =
  Notification
    { channel = Text.decodeUtf8 (LibPQ.notifyRelname notification),
      payload = LibPQ.notifyExtra notification
    }
