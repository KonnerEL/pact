{-# LANGUAGE CPP #-}
{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE DeriveFoldable #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE RecordWildCards #-}
{-# OPTIONS_GHC -fno-warn-orphans #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE FlexibleContexts #-}

-- |
-- Module      :  Pact.Types.Command
-- Copyright   :  (C) 2016 Stuart Popejoy, Will Martino
-- License     :  BSD-style (see the file LICENSE)
-- Maintainer  :  Stuart Popejoy <stuart@kadena.io>, Will Martino <will@kadena.io>
--
-- Specifies types for commands in a consensus/DL setting.
--

module Pact.Types.Command
  ( Command(..),cmdPayload,cmdSigs,cmdHash
#if !defined(ghcjs_HOST_OS)
  , mkCommand, mkCommand', mkUserSig, verifyUserSig, verifyCommand
#else
  , PPKScheme(..)
#endif
  , ProcessedCommand(..),_ProcSucc,_ProcFail
  , Payload(..),pMeta,pNonce,pPayload
  , ParsedCode(..),pcCode,pcExps
  , UserSig(..),usScheme,usPubKey,usAddress,usSig
  , CommandError(..),ceMsg,ceDetail
  , CommandSuccess(..),csData
  , CommandResult(..),crReqKey,crTxId,crResult,crGas
  , ExecutionMode(..), emTxId
  , CommandExecInterface(..),ceiApplyCmd,ceiApplyPPCmd
  , ApplyCmd, ApplyPPCmd
  , RequestKey(..)
  , cmdToRequestKey, requestKeyToB16Text
  ) where


import Control.Applicative
import Control.Lens hiding ((.=))
import Control.Monad.Reader
import Control.DeepSeq
import Data.ByteString (ByteString)
import Data.Serialize as SZ
import Data.String
import Data.Hashable (Hashable)
import Data.Aeson as A
import Data.Text hiding (filter, all)
import Data.Maybe  (fromMaybe)


import GHC.Generics
import Prelude

import Pact.Types.Runtime hiding (PublicKey)
import Pact.Types.Orphans ()
import Pact.Types.RPC


#if !defined(ghcjs_HOST_OS)
import qualified Data.ByteString.Lazy as BSL

import Pact.Parse (parseExprs)
import Pact.Types.Crypto              as Base
#else
import Pact.Types.Scheme (PPKScheme(..), defPPKScheme)
#endif


-- | Command is the signed, hashed envelope of a Pact execution instruction or command.
-- In 'Command ByteString', the 'ByteString' payload is hashed and signed; the ByteString
-- being the JSON serialization of 'Payload Text', where the 'Text' is the pact code; when
-- executed this is parsed to 'ParsedCode'.
-- Thus, 'Command (Payload m ParsedCode)' (with m representing platform-specific metadata)
-- is the fully executable specialization.
data Command a = Command
  { _cmdPayload :: !a
  , _cmdSigs :: ![UserSig]
  , _cmdHash :: !PactHash
  } deriving (Eq,Show,Ord,Generic,Functor,Foldable,Traversable)
instance (Serialize a) => Serialize (Command a)
instance (ToJSON a) => ToJSON (Command a) where
    toJSON (Command payload uSigs hsh) =
        object [ "cmd" .= payload
               , "sigs" .= toJSON uSigs
               , "hash" .= hsh
               ]
instance (FromJSON a) => FromJSON (Command a) where
    parseJSON = withObject "Command" $ \o ->
                Command <$> (o .: "cmd")
                        <*> (o .: "sigs" >>= parseJSON)
                        <*> (o .: "hash")
    {-# INLINE parseJSON #-}

instance NFData a => NFData (Command a)


-- | Strict Either thing for attempting to deserialize a Command.
data ProcessedCommand m a =
  ProcSucc !(Command (Payload m a)) |
  ProcFail !String
  deriving (Show, Eq, Generic, Functor, Foldable, Traversable)
instance (NFData a,NFData m) => NFData (ProcessedCommand m a)


#if !defined(ghcjs_HOST_OS)


mkCommand :: (ToJSON m, ToJSON c) =>
             [SomeKeyPair] -> m ->
             Text -> PactRPC c -> IO (Command ByteString)
mkCommand creds meta nonce a = mkCommand' creds $ BSL.toStrict $ A.encode (Payload a nonce meta)


mkCommand' :: [SomeKeyPair] -> ByteString -> IO (Command ByteString)
mkCommand' creds env = makeCommand <$> (traverse makeSigs creds)
  where makeCommand sigs = Command env sigs hsh
        hsh = hash env    -- hash associated with a Command, aka a Command's Request Key
        makeSigs kp = mkUserSig hsh kp

mkUserSig :: PactHash -> SomeKeyPair -> IO UserSig
mkUserSig hsh kp =
  let pub = toB16Text $ getPublic kp
      formattedPub = toB16Text $ formatPublicKey kp
      sig = toB16Text <$> sign kp (toUntypedHash hsh)
  in UserSig (kpToPPKScheme kp) pub formattedPub <$> sig



verifyCommand :: FromJSON m => Command ByteString -> ProcessedCommand m ParsedCode
verifyCommand orig@Command{..} = case (ppcmdPayload', ppcmdHash', mSigIssue) of
      (Right env', Right _, Nothing) -> ProcSucc $ orig { _cmdPayload = env' }
      (e, h, s) -> ProcFail $ "Invalid command: " ++ toErrStr e ++ toErrStr h ++ fromMaybe "" s
  where
    ppcmdPayload' = traverse parsePact =<< A.eitherDecodeStrict' _cmdPayload
    parsePact :: Text -> Either String ParsedCode
    parsePact code = ParsedCode code <$> parseExprs code
    (ppcmdSigs' :: [(UserSig,Bool)]) = (\u -> (u,verifyUserSig _cmdHash u)) <$> _cmdSigs
    ppcmdHash' = verifyHash _cmdHash _cmdPayload
    mSigIssue = if all snd ppcmdSigs' then Nothing
      else Just $ "Invalid sig(s) found: " ++ show (A.encode . fst <$> filter (not.snd) ppcmdSigs')
    toErrStr :: Either String a -> String
    toErrStr (Right _) = ""
    toErrStr (Left s) = s ++ "; "
{-# INLINE verifyCommand #-}


verifyUserSig :: PactHash -> UserSig -> Bool
verifyUserSig msg UserSig{..} =
  case (pubT, sigT, addrT) of
    (Right p, Right sig, Right addr) ->
      (isValidAddr addr p) && verify (toScheme _usScheme) (toUntypedHash msg) (PubBS p) (SigBS sig)
    _ -> False
  where pubT = parseB16TextOnly _usPubKey
        sigT = parseB16TextOnly _usSig
        addrT = parseB16TextOnly _usAddress
        isValidAddr givenAddr pubBS =
          case formatPublicKeyBS (toScheme _usScheme) (PubBS pubBS) of
            Right expectAddr -> givenAddr == expectAddr
            Left _           -> False

#endif


-- | Pair parsed Pact expressions with the original text.
data ParsedCode = ParsedCode
  { _pcCode :: !Text
  , _pcExps :: ![Exp Parsed]
  } deriving (Eq,Show,Generic)
instance NFData ParsedCode


-- | Payload combines a 'PactRPC' with a nonce and platform-specific metadata.
data Payload m c = Payload
  { _pPayload :: !(PactRPC c)
  , _pNonce :: !Text
  , _pMeta :: !m
  } deriving (Show, Eq, Generic, Functor, Foldable, Traversable)
instance (NFData a,NFData m) => NFData (Payload m a)
instance (ToJSON a,ToJSON m) => ToJSON (Payload m a) where toJSON = lensyToJSON 2
instance (FromJSON a,FromJSON m) => FromJSON (Payload m a) where parseJSON = lensyParseJSON 2


-- | UserSig combines PPKScheme, PublicKey, and the formatted PublicKey
--   referred to as the Address.
data UserSig = UserSig
  { _usScheme :: !PPKScheme
  , _usPubKey :: !Text
  , _usAddress :: !Text
  , _usSig :: !Text }
  deriving (Eq, Ord, Show, Generic)
instance NFData UserSig


instance Serialize UserSig
instance ToJSON UserSig where
  toJSON UserSig {..} = object [
    "scheme" .= _usScheme, "pubKey" .= _usPubKey, "addr" .= _usAddress, "sig" .= _usSig ]
instance FromJSON UserSig where
  parseJSON = withObject "UserSig" $ \o -> do
    pub <- o .: "pubKey"
    sig <- o .: "sig"

    scheme <- o .:? "scheme"   -- defaults to PPKScheme default
    addr <- o .:? "addr"       -- defaults to full Public Key

    return $ UserSig (fromMaybe defPPKScheme scheme) pub (fromMaybe pub addr) sig



data CommandError = CommandError {
      _ceMsg :: String
    , _ceDetail :: Maybe String
}
instance ToJSON CommandError where
    toJSON (CommandError m d) =
        object $ [ "status" .= ("failure" :: String)
                 , "error" .= m ] ++
        maybe [] ((:[]) . ("detail" .=)) d

newtype CommandSuccess a = CommandSuccess { _csData :: a }
  deriving (Eq, Show)

instance (ToJSON a) => ToJSON (CommandSuccess a) where
    toJSON (CommandSuccess a) =
        object [ "status" .= ("success" :: String)
               , "data" .= a ]

instance (FromJSON a) => FromJSON (CommandSuccess a) where
    parseJSON = withObject "CommandSuccess" $ \o ->
        CommandSuccess <$> o .: "data"

data CommandResult = CommandResult
  { _crReqKey :: RequestKey
  , _crTxId :: Maybe TxId
  , _crResult :: Value
  , _crGas :: Gas
  } deriving (Eq,Show)


cmdToRequestKey :: Command a -> RequestKey
cmdToRequestKey Command {..} = RequestKey (toUntypedHash _cmdHash)


data ExecutionMode =
    Transactional { _emTxId :: TxId } |
    Local
    deriving (Eq,Show)


type ApplyCmd = ExecutionMode -> Command ByteString -> IO CommandResult
type ApplyPPCmd m a = ExecutionMode -> Command ByteString -> ProcessedCommand m a -> IO CommandResult

data CommandExecInterface m a = CommandExecInterface
  { _ceiApplyCmd :: ApplyCmd
  , _ceiApplyPPCmd :: ApplyPPCmd m a
  }


requestKeyToB16Text :: RequestKey -> Text
requestKeyToB16Text (RequestKey h) = hashToText h


newtype RequestKey = RequestKey { unRequestKey :: Hash}
  deriving (Eq, Ord, Generic, Serialize, Hashable, ParseText, FromJSON, ToJSON)

instance Show RequestKey where
  show (RequestKey rk) = show rk



makeLenses ''UserSig
makeLenses ''CommandExecInterface
makeLenses ''ExecutionMode
makeLenses ''Command
makeLenses ''ParsedCode
makeLenses ''Payload
makeLenses ''CommandError
makeLenses ''CommandSuccess
makeLenses ''CommandResult
makePrisms ''ProcessedCommand
makePrisms ''ExecutionMode
