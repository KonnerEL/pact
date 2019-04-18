{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE CPP #-}

module SchemeSpec (spec) where

import Test.Hspec
import System.IO.Error
import Data.Text (Text)
import Data.ByteString (ByteString)
import Data.Aeson as A
import qualified Control.Lens             as Lens
import qualified Data.ByteString.Base16   as B16
import qualified Crypto.Hash              as H
import qualified Data.ByteString.Lazy     as BSL

import Pact.ApiReq
import Pact.Types.Crypto
import Pact.Types.Command
import Pact.Types.Util (toB16Text, fromJSON')
import Pact.Types.RPC



---- HELPER DATA TYPES AND FUNCTIONS ----

getByteString :: ByteString -> ByteString
getByteString = fst . B16.decode


type Address = Text

getKeyPairComponents :: SomeKeyPair -> (PublicKeyBS, PrivateKeyBS, Address, PPKScheme)
getKeyPairComponents kp = (PubBS $ getPublic kp,
                           PrivBS $ getPrivate kp,
                           toB16Text $ formatPublicKey kp,
                           kpToPPKScheme kp)


someED25519Pair :: (PublicKeyBS, PrivateKeyBS, Address, PPKScheme)
someED25519Pair = (PubBS $ getByteString
                   "ba54b224d1924dd98403f5c751abdd10de6cd81b0121800bf7bdbdcfaec7388d",
                   PrivBS $ getByteString
                   "8693e641ae2bbe9ea802c736f42027b03f86afe63cae315e7169c9c496c17332",
                   "ba54b224d1924dd98403f5c751abdd10de6cd81b0121800bf7bdbdcfaec7388d",
                   ED25519)

someETHPair :: (PublicKeyBS, PrivateKeyBS, Address, PPKScheme)
someETHPair = (PubBS $ getByteString
               "836b35a026743e823a90a0ee3b91bf615c6a757e2b60b9e1dc1826fd0dd16106f7bc1e8179f665015f43c6c81f39062fc2086ed849625c06e04697698b21855e",
               PrivBS $ getByteString
               "208065a247edbe5df4d86fbdc0171303f23a76961be9f6013850dd2bdc759bbb",
               "0bed7abd61247635c1973eb38474a2516ed1d884",
               ETH)


toApiKeyPairs :: [(PublicKeyBS, PrivateKeyBS, Address, PPKScheme)] -> [ApiKeyPair]
toApiKeyPairs kps = map makeAKP kps
  where makeAKP (pub, priv, add, scheme) =
          ApiKeyPair priv (Just pub) (Just add) (Just scheme)


mkCommandTest :: [SomeKeyPair] -> [Signer] -> Text -> IO (Command ByteString)
mkCommandTest kps signers code = mkCommand' kps $ toExecPayload signers code


toSigners :: [(PublicKeyBS, PrivateKeyBS, Address, PPKScheme)] -> IO [Signer]
toSigners kps = return $ map makeSigner kps
  where makeSigner (PubBS pub, _, add, scheme) =
          Signer scheme (toB16Text pub) add


toExecPayload :: [Signer] -> Text -> ByteString
toExecPayload signers t = BSL.toStrict $ A.encode payload
  where payload = (Payload (Exec (ExecMsg t Null)) "nonce" () signers)


shouldBeProcFail ::  ProcessedCommand () ParsedCode -> Expectation
shouldBeProcFail pcmd = pcmd `shouldSatisfy` isProcFail
  where isProcFail result = case result of
          ProcFail _ -> True
          _ -> False



---- HSPEC TESTS ----

#if !defined(ghcjs_HOST_OS)
spec :: Spec
spec = describe "working with crypto schemes" $ do
  describe "test importing Key Pair for each Scheme" testKeyPairImport
  describe "test default scheme in ApiKeyPair" testDefSchemeApiKeyPair
  describe "test for correct address in ApiKeyPair" testAddrApiKeyPair
  describe "test PublicKey import" testPublicKeyImport
  describe "test UserSig creation and verificaton" testUserSig
  describe "test signature non-malleability" testSigNonMalleability
#else
spec = return ()
#endif

testKeyPairImport :: Spec
testKeyPairImport = do
  it "imports ED25519 Key Pair" $ do
    kp <- mkKeyPairs (toApiKeyPairs [someED25519Pair])
    (map getKeyPairComponents kp) `shouldBe` [someED25519Pair]

  it "imports ETH Key Pair" $ do
    kp <- mkKeyPairs (toApiKeyPairs [someETHPair])
    (map getKeyPairComponents kp) `shouldBe` [someETHPair]



testDefSchemeApiKeyPair :: Spec
testDefSchemeApiKeyPair =
  context "when scheme not provided in API" $
    it "makes the scheme the default PPKScheme" $ do
      let (pub, priv, addr, _) = someED25519Pair
          apiKP = ApiKeyPair priv (Just pub) (Just addr) Nothing
      kp <- mkKeyPairs [apiKP]
      (map getKeyPairComponents kp) `shouldBe` [someED25519Pair]



testAddrApiKeyPair :: Spec
testAddrApiKeyPair =
  it "throws error when address provided in API doesn't match derived address" $ do
     let (pub, priv, _, scheme) = someETHPair
         apiKP = ApiKeyPair priv (Just pub) (Just "9f491e44a3f87df60d6cb0eefd5a9083ae6c3f32") (Just scheme)
     mkKeyPairs [apiKP] `shouldThrow` isUserError



testPublicKeyImport :: Spec
testPublicKeyImport = do
  it "derives PublicKey from the PrivateKey when PublicKey not provided" $ do
    let (_, priv, addr, scheme) = someETHPair
        apiKP = ApiKeyPair priv Nothing (Just addr) (Just scheme)
    kp <- mkKeyPairs [apiKP]
    (map getKeyPairComponents kp) `shouldBe` [someETHPair]


  it "throws error when PublicKey provided does not match derived PublicKey" $ do
    let (_, priv, addr, scheme) = someETHPair
        fakePub = PubBS $ getByteString
                  "c640e94730fb7b7fce01b11086645741fcb5174d1c634888b9d146613730243a171833259cd7dab9b3435421dcb2816d3efa55033ff0899de6cc8b1e0b20e56c"
        apiKP   = ApiKeyPair priv (Just fakePub) (Just addr) (Just scheme)
    mkKeyPairs [apiKP] `shouldThrow` isUserError



testUserSig :: Spec
testUserSig = do
  it "successfully verifies ETH UserSig when using Command's mkCommand" $ do
    signers <- toSigners [someETHPair]
    kps     <- mkKeyPairs $ toApiKeyPairs [someETHPair]
    cmd     <- mkCommandTest kps signers "(somePactFunction)"
    let (hsh, sigs)  = (_cmdHash cmd, _cmdSigs cmd)
        verifiedSigs = (map (\(sig, signer) -> verifyUserSig hsh sig signer)
                            (zip sigs signers))
    verifiedSigs `shouldBe` [True]



  it "successfully verifies ETH UserSig when provided by user" $ do
    -- UserSig verification will pass but Command verification might fail
    -- if hash algorithm provided not supported for hashing commands.
    let hsh = hashTx "(somePactFunction)" H.SHA3_256
    [signer] <- toSigners [someETHPair]
    [kp]     <- mkKeyPairs $ toApiKeyPairs [someETHPair]
    sig      <- sign kp hsh
    let myUserSig = UserSig (toB16Text sig)
    (verifyUserSig hsh myUserSig signer) `shouldBe` True



  it "fails UserSig validation when UserSig has unexpected Address" $ do
    let hsh = hashTx "(somePactFunction)" H.Blake2b_512
    [signer] <- toSigners [someETHPair]
    [kp]     <- mkKeyPairs $ toApiKeyPairs [someETHPair]
    sig      <- sign kp hsh
    let myUserSig   = UserSig (toB16Text sig)
        wrongAddr   = Lens.view siPubKey signer
        wrongSigner = Lens.set siAddress wrongAddr signer
    (verifyUserSig hsh myUserSig wrongSigner) `shouldBe` False



  it "fails UserSig validation when UserSig has unexpected Scheme" $ do
    let hsh = hashTx "(somePactFunction)" H.Blake2b_512
    [signer] <- toSigners [someETHPair]
    [kp]     <- mkKeyPairs $ toApiKeyPairs [someETHPair]
    sig      <- sign kp hsh
    let myUserSig   = UserSig (toB16Text sig)
        wrongScheme = ED25519
        wrongSigner = Lens.set siScheme wrongScheme signer
    (verifyUserSig hsh myUserSig wrongSigner) `shouldBe` False



  it "provides default ppkscheme when one not provided" $ do
    let sigJSON = A.object ["addr" .= String "SomeAddr", "pubKey" .= String "SomePubKey",
                            "sig" .= String "SomeSig"]
        sig     = UserSig "SomeSig"
    (fromJSON' sigJSON) `shouldBe` (Right sig)



  it "makes address field the full public key when one not provided" $ do
    let sigJSON = A.object ["pubKey" .= String "SomePubKey", "sig" .= String "SomeSig"]
        sig     = UserSig "SomeSig"
    (fromJSON' sigJSON) `shouldBe` (Right sig)



testSigNonMalleability :: Spec
testSigNonMalleability = do
  it "fails when invalid signature provided for signer specified in the payload" $ do
    wrongSigners <- toSigners [someED25519Pair]
    kps          <- mkKeyPairs $ toApiKeyPairs [someETHPair]
    
    cmdWithWrongSig <- mkCommandTest kps wrongSigners "(somePactFunction)"
    shouldBeProcFail (verifyCommand cmdWithWrongSig)



  it "fails when number of signatures does not match number of payload signers" $ do
    [signer]  <- toSigners [someETHPair]
    [kp]      <- mkKeyPairs $ toApiKeyPairs [someETHPair]
    [wrongKp] <- mkKeyPairs $ toApiKeyPairs [someED25519Pair]

    cmdWithWrongNumSig <- mkCommandTest [kp, wrongKp] [signer] "(somePactFunction)"
    shouldBeProcFail (verifyCommand cmdWithWrongNumSig)
