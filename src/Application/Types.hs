{-# LANGUAGE
    OverloadedStrings
  , ConstraintKinds
  , FlexibleContexts
  , MultiParamTypeClasses
  , DeriveGeneric
  , RecordWildCards
  , NamedFieldPuns
  , CPP
  #-}

module Application.Types where

import Data.Process (ProcessHandles)
import Data.Json.RPC (RPCConfig)
import Monero.Wallet.Process (WalletProcessConfig (..), closeWallet)

import Data.Strict.Tuple (Pair ((:!:)))
import Data.Url
import Data.Aeson as A
import Data.Aeson.Types (typeMismatch)
import Data.Default
import Data.Aeson.Encode.Pretty as A hiding (Config)
import qualified Data.Map.Strict as Map
import Data.STRef
import Path.Extended hiding ((</>))
import Control.Monad.Catch
import Control.Monad.Reader
import Control.Monad.Logger
import Control.Monad.ST
import Control.Concurrent.Async

import GHC.Generics
import qualified Data.Text as T
import qualified Data.Text.Lazy as LT
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as LBS
import qualified Data.ByteString.Base64 as BS64
import Network (HostName, PortNumber)
import System.FilePath ((</>))
import System.Process (readCreateProcessWithExitCode, shell)
import System.Exit

import Crypto.Saltine.Core.Box (PublicKey, SecretKey)
import Crypto.Saltine.Class as NaCl
import Web.Routes.Nested (textOnly)
import Network.Wai.Trans (ApplicationT)
import Network.HTTP.Types (status400, status401)
import Network.WebSockets (DataMessage)


-- * Infrastructure of the App


-- ** Read-Only Data

data Env = Env
  { envAuthority   :: UrlAuthority
  , envWrkDir      :: FilePath
  , envCertPk      :: PublicKey
  , envCertSk      :: SecretKey
  , envInstPk      :: PublicKey
  , envInstSk      :: SecretKey
  , envOpenWallets :: STRef RealWorld (Map.Map T.Text (Pair RPCConfig ProcessHandles))
                   -- ^ wallet_name -> process_handles
  , envProgresses  :: STRef RealWorld (Map.Map T.Text (Async T.Text))
                   -- ^ rpc_id -> async <mnemonic> -- FIXME: should be unique per client
  , envMutable     :: STRef RealWorld Mutable
  } deriving (Eq)

instance Show Env where
  show Env{..} = unlines
    [ "Env:  - host: " ++ showUrlAuthority envAuthority
    , "      - dir:  " ++ envWrkDir
    , "      - cert public key: " ++ show (BS64.encode $ NaCl.encode envCertPk)
    , "      - cert secret key: <###>"
    , "      - inst public key: " ++ show (BS64.encode $ NaCl.encode envInstPk)
    , "      - inst secret key: <###>"
    ]


-- ** Stateful Data

data Config = Config
  { configWalletsPath        :: FilePath
  , configWallets            :: [String]
  , configConcurrentWallets  :: Int
  , configWalletStartingPort :: PortNumber
  , configMoneroWalletCli    :: FilePath
  , configDaemonHost         :: HostName
  , configDaemonPort         :: PortNumber
  -- , configDefaultLanguage :: Language
  } deriving (Show, Eq)

instance Default Config where
  def = Config
    { configWalletsPath        = "" -- gets overwritten
    , configWallets            = [] -- gets overwritten
    , configConcurrentWallets  = 1
    , configWalletStartingPort = 18082
#ifdef mingw32_HOST_OS
    , configMoneroWalletCli    = "monero-wallet-cli.exe"
#else
    , configMoneroWalletCli    = "monero-wallet-cli"
#endif
    , configDaemonHost         = "node.moneybit.science"
    , configDaemonPort         = 18081
    }

instance ToJSON Config where
  toJSON Config{..} = object
    [ "walletPath"         .= configWalletsPath
    , "wallets"            .= configWallets
    , "concurrentWallets"  .= configConcurrentWallets
    , "walletStartingPort" .= (fromIntegral configWalletStartingPort :: Int)
    , "moneroWalletCli"    .= configMoneroWalletCli
    , "daemonHost"         .= configDaemonHost
    , "daemonPort"         .= (fromIntegral configDaemonPort :: Int)
    ]

instance FromJSON Config where
  parseJSON (Object o) = do
    p  <- o .: "walletPath"
    ws <- o .: "wallets"
    cw <- o .:? "concurrentWallets" .!= 1
    wp <- getPN <$> o .:? "walletStartingPort" .!= 18082
    mw <- o .:? "moneroWalletCli" .!= "monero-wallet-cli"
    dh <- o .:? "daemonHost" .!= "node.moneybit.science"
    dp <- getPN <$> o .:? "daemonPort" .!= 18081
    pure Config
      { configWalletsPath        = p
      , configWallets            = ws
      , configConcurrentWallets  = cw
      , configWalletStartingPort = wp
      , configMoneroWalletCli    = mw
      , configDaemonHost         = dh
      , configDaemonPort         = dp
      }
    where
      getPN :: Int -> PortNumber
      getPN = fromIntegral
  parseJSON x = typeMismatch "Config" x


makeWalletProcessConfig :: MonadApp m => m WalletProcessConfig
makeWalletProcessConfig = do
  Env{envOpenWallets,envMutable} <- ask
  Config{..} <- liftIO $ stToIO $ config <$> readSTRef envMutable
  wallets    <- liftIO $ stToIO $ readSTRef envOpenWallets
  if Map.size wallets >= configConcurrentWallets
  then throwM MaxConcurrentOpenWallets
  else do
    port <- nextAvailPort
    pure def
      { walletsDir          = configWalletsPath
      , walletRpcPort       = port
      , moneroWalletCliPath = configMoneroWalletCli
      , walletDaemonHost    = configDaemonHost
      , walletDaemonPort    = configDaemonPort
      }


nextAvailPort :: MonadApp m => m PortNumber
nextAvailPort = do
  Env{envMutable} <- ask
  startingPort <- liftIO $ stToIO $
    configWalletStartingPort . config <$> readSTRef envMutable
  go startingPort
  where
    go p = do
      isAvail <- liftIO $ portIsAvail p
      if isAvail then pure p else go $ p + 1


portIsAvail :: PortNumber -> IO Bool
portIsAvail p = do
  (e,xs,_) <- readCreateProcessWithExitCode (shell $ "lsof -i :" ++ show p) ""
  case (e,xs) of
    (ExitFailure 1, "") -> pure True
    (ExitSuccess, _)    -> pure False
    _                   -> error $ "lsof failed: " ++ show (e,xs, "lsof -i :" ++ show p)


-- | Update the config file every time it's changed in the UI
configure :: (Config -> Config)
          -> AppM ()
configure f = do
  Env {envWrkDir,envOpenWallets,envMutable} <- ask
  m@Mutable{config} <- liftIO $ stToIO $ readSTRef envMutable
  let config' = f config
  when (configWalletsPath config' /= configWalletsPath config) $ do
    liftIO $ do
      ws <- stToIO $ Map.elems <$> readSTRef envOpenWallets
      forM_ ws $ \(_ :!: hs) -> closeWallet hs
    -- FIXME: actually move wallet files
    -- FIXME: genuine semantic design - file paths should be independent for each wallet
  liftIO $ do
    stToIO $ writeSTRef envMutable $ m { config = config' }
    LBS.writeFile (envWrkDir </> "config.json") $ A.encodePretty config'


data Mutable = Mutable
  { config :: Config
  , rpcId  :: Int
  } deriving (Show, Eq)

mkMutable :: Config -> Mutable
mkMutable c = Mutable
  { config = c
  , rpcId  = 0
  }


-- * Effect


type AppM = LoggingT (ReaderT Env IO)

runAppM :: Env -> AppM a -> IO a
runAppM env xs = runReaderT (runStderrLoggingT xs) env

type MonadApp m =
  ( MonadReader Env m
  , MonadIO m
  , MonadThrow m
  , MonadCatch m
  , MonadMask m
  )


-- * Links

data AppLinks
  = AppWallets

instance ToPath AppLinks Abs File where
  toPath AppWallets = parseAbsFile "/index"

instance ToLocation AppLinks Abs File where
  toLocation AppWallets = fromPath <$> toPath AppWallets


data AssetLinks
  = JQuery
  | SemanticCss
  | SemanticJs
  | Qrious
  | CryptoCoinsCss
  | CryptoCoinsColorsCss
  | ClipboardJs
  | ScryptJs
  | NaClJs
  | ZxcvbnJs

instance ToPath AssetLinks Abs File where
  toPath JQuery      = parseAbsFile "/static/jquery"
  toPath SemanticCss = parseAbsFile "/static/semantic/semantic"
  toPath SemanticJs  = parseAbsFile "/static/semantic/semantic"
  toPath Qrious      = parseAbsFile "/static/qrious"
  toPath CryptoCoinsCss = parseAbsFile "/static/cryptocoins/cryptocoins"
  toPath CryptoCoinsColorsCss = parseAbsFile "/static/cryptocoins/cryptocoins-colors"
  toPath ClipboardJs = parseAbsFile "/static/clipboard"
  toPath ScryptJs    = parseAbsFile "/static/scrypt"
  toPath NaClJs      = parseAbsFile "/static/nacl"
  toPath ZxcvbnJs    = parseAbsFile "/static/zxcvbn"

instance ToLocation AssetLinks Abs File where
  toLocation JQuery      = (addFileExt "min.js" . fromPath) <$> toPath JQuery
  toLocation SemanticCss = (addFileExt "css"    . fromPath) <$> toPath SemanticCss
  toLocation SemanticJs  = (addFileExt "js"     . fromPath) <$> toPath SemanticJs
  toLocation Qrious      = (addFileExt "js"     . fromPath) <$> toPath Qrious
  toLocation CryptoCoinsCss = (addFileExt "css" . fromPath) <$> toPath CryptoCoinsCss
  toLocation CryptoCoinsColorsCss = (addFileExt "css" . fromPath) <$> toPath CryptoCoinsColorsCss
  toLocation ClipboardJs = (addFileExt "js"     . fromPath) <$> toPath ClipboardJs
  toLocation ScryptJs    = (addFileExt "js"     . fromPath) <$> toPath ScryptJs
  toLocation NaClJs      = (addFileExt "js"     . fromPath) <$> toPath NaClJs
  toLocation ZxcvbnJs    = (addFileExt "js"     . fromPath) <$> toPath ZxcvbnJs



-- * Exceptions

data InitException
  = MalformedConfigFile LBS.ByteString
  | NonexistentWallet String
  deriving (Show, Eq, Generic)
instance Exception InitException

data ProcessException
  = NotEnoughHandles String
  deriving (Show, Eq, Generic)
instance Exception ProcessException

data ApiException
  = TranscodeDecodeError LBS.ByteString
  | TranscodeDecodeByteError BS.ByteString
  | OpenDecodeError LBS.ByteString
  | NewDecodeError LBS.ByteString
  | RecoverDecodeError LBS.ByteString
  | HistoryDecodeError LBS.ByteString
  | IntegratedDecodeError LBS.ByteString
  | SendDecodeError LBS.ByteString
  | ConfigDecodeError LBS.ByteString
  deriving (Show, Eq, Generic)
instance Exception ApiException

catchApiException :: ApiException -> ApplicationT AppM
catchApiException e req resp = resp $ textOnly (LT.pack $ show e) status400 []

data AuthException
  = WalletNotOpen T.Text
  | MaxConcurrentOpenWallets
  deriving (Show, Eq, Generic)
instance Exception AuthException


catchAuthException :: AuthException -> ApplicationT AppM
catchAuthException e req resp = resp $ textOnly (LT.pack $ show e) status401 []


data WebSocketException
  = UnsupportedReceivedData DataMessage
  deriving (Show, Eq, Generic)
instance Exception WebSocketException
