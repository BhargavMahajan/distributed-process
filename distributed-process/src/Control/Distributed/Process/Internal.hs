module Control.Distributed.Process.Internal 
  ( -- * Global CH state
    RemoteTable
  , initRemoteTable
  , -- * Node and process identifiers 
    NodeId(..)
  , LocalProcessId(..)
  , ProcessId(..)
    -- * Local nodes and processes
  , LocalNode(..)
  , LocalNodeState(..)
  , LocalProcess(..)
  , LocalProcessState(..)
    -- * Messages 
  , Message(..)
    -- * Monitoring and linking
  , MonitorRef(..)
  , MonitorNotification(..)
  , LinkException(..)
  , DiedReason(..)
  , DidUnmonitor(..)
  , DidUnlink(..)
    -- * Node controller data types
  , Identifier
  , NCMsg(..)
  , ProcessSignal(..)
    -- * Serialization/deserialization
  , createMessage
  , messageToPayload
  , payloadToMessage
  , idToPayload
  , payloadToId
    -- * Accessors
  , localProcesses
  , localPidCounter
  , localPidUnique
  , localMonitorCounter
  , localProcessWithId
  , connections
  , connectionTo
  ) where

import Control.Concurrent (ThreadId)
import Control.Concurrent.MVar (MVar)
import Control.Concurrent.Chan (Chan)
import Control.Category ((>>>))
import Control.Exception (Exception)
import Data.Map (Map)
import qualified Data.Map as Map (empty)
import Data.Int (Int32)
import Data.Typeable (Typeable)
import Data.Dynamic (Dynamic) 
import Data.Binary (Binary, encode, put, get, putWord8, getWord8)
import Data.Accessor (Accessor, accessor)
import qualified Data.Accessor.Container as DAC (mapMaybe)
import qualified Data.ByteString.Lazy as BSL (ByteString, toChunks, fromChunks, splitAt)
import qualified Data.ByteString as BSS (ByteString, concat, splitAt)
import qualified Network.Transport as NT (EndPoint, EndPointAddress, Connection)
import qualified Network.Transport.Internal as NTI (encodeInt32, decodeInt32)
import Control.Applicative ((<$>), (<*>))
import Control.Distributed.Process.Serializable ( Fingerprint
                                                , Serializable
                                                , encodeFingerprint
                                                , decodeFingerprint
                                                , fingerprint
                                                , sizeOfFingerprint
                                                )
import Control.Distributed.Process.Internal.CQueue (CQueue)

-- | Node identifier 
newtype NodeId = NodeId { nodeAddress :: NT.EndPointAddress }
  deriving (Eq, Ord, Binary)

instance Show NodeId where
  show = show . nodeAddress

-- | A local process ID consists of a seed which distinguishes processes from
-- different instances of the same local node and a counter
data LocalProcessId = LocalProcessId 
  { lpidUnique  :: Int32
  , lpidCounter :: Int32
  }
  deriving (Eq, Ord, Typeable)

instance Show LocalProcessId where
  show = show . lpidCounter 

-- | Process identifier
data ProcessId = ProcessId 
  { processNodeId  :: NodeId
  , processLocalId :: LocalProcessId 
  }
  deriving (Eq, Ord, Typeable)

instance Show ProcessId where
  show pid = show (processNodeId pid) ++ ":" ++ show (processLocalId pid)

-- | Used to fake 'static' (see paper)
type RemoteTable = Map String Dynamic 

-- | Initial (empty) remote-call meta data
initRemoteTable :: RemoteTable
initRemoteTable = Map.empty

-- | Local nodes
data LocalNode = LocalNode 
  { localNodeId   :: NodeId
  , localEndPoint :: NT.EndPoint 
  , localState    :: MVar LocalNodeState
  , localCtrlChan :: Chan NCMsg
  -- TODO: this should be part of the CH state, not the local endpoint state
  , remoteTable   :: RemoteTable 
  }

-- | Local node state
data LocalNodeState = LocalNodeState 
  { _localProcesses      :: Map LocalProcessId LocalProcess
  , _localPidCounter     :: Int32
  , _localPidUnique      :: Int32
  , _localMonitorCounter :: Int32
  }

-- | Processes running on our local node
data LocalProcess = LocalProcess 
  { processQueue  :: CQueue Message 
  , processNode   :: LocalNode   
  , processId     :: ProcessId
  , processState  :: MVar LocalProcessState
  , processThread :: ThreadId
  }

-- | Local process state
data LocalProcessState = LocalProcessState
  { _connections    :: Map ProcessId NT.Connection 
  }

-- | Messages consist of their typeRep fingerprint and their encoding
data Message = Message 
  { messageFingerprint :: Fingerprint 
  , messageEncoding    :: BSL.ByteString
  }

-- | MonitorRef is opaque for regular Cloud Haskell processes 
data MonitorRef = MonitorRef 
  { monitorRefPid     :: ProcessId
  , monitorRefCounter :: Int32
  }
  deriving (Eq, Ord, Show)

-- | Messages sent by monitors
data MonitorNotification = MonitorNotification MonitorRef ProcessId DiedReason
  deriving (Typeable)

-- | Exceptions thrown when a linked process dies
data LinkException = LinkException ProcessId DiedReason
  deriving (Typeable, Show)

instance Exception LinkException

-- | (Asynchronous) reply from unmonitor
newtype DidUnmonitor = DidUnmonitor MonitorRef
  deriving (Typeable, Binary)

-- | (Asynchronous) reply from unlink
newtype DidUnlink = DidUnlink ProcessId
  deriving (Typeable, Binary)

-- | Why did a process die?
data DiedReason = 
    -- | Normal termination
    DiedNormal
    -- | The process exited with an exception
    -- (provided as 'String' because 'Exception' does not implement 'Binary')
  | DiedException String
    -- | We got disconnected from the process node
  | DiedDisconnect
    -- | The process node died
  | DiedNodeDown
    -- | Invalid process ID
  | DiedNoProc
  deriving (Show, Eq)

-- | Node or process identifier
type Identifier = Either ProcessId NodeId

-- | Messages to the node controller
data NCMsg = NCMsg 
  { ctrlMsgSender :: Identifier 
  , ctrlMsgSignal :: ProcessSignal
  }
  deriving Show

-- | Signals to the node controller (see 'NCMsg')
data ProcessSignal =
    Link ProcessId
  | Unlink ProcessId
  | Monitor ProcessId MonitorRef
  | Unmonitor MonitorRef
  | Died Identifier DiedReason
  deriving Show

--------------------------------------------------------------------------------
-- Serialization/deserialization                                              --
--------------------------------------------------------------------------------

-- | Turn any serialiable term into a message
createMessage :: Serializable a => a -> Message
createMessage a = Message (fingerprint a) (encode a)

-- | Serialize a message
messageToPayload :: Message -> [BSS.ByteString]
messageToPayload (Message fp enc) = encodeFingerprint fp : BSL.toChunks enc

-- | Deserialize a message
payloadToMessage :: [BSS.ByteString] -> Message
payloadToMessage payload = Message fp msg
  where
    (encFp, msg) = BSL.splitAt (fromIntegral sizeOfFingerprint) 
                 $ BSL.fromChunks payload 
    fp = decodeFingerprint . BSS.concat . BSL.toChunks $ encFp


-- | The first message we send across a connection to indicate the intended
-- recipient. Pass Nothing for the remote node controller
idToPayload :: Maybe LocalProcessId -> [BSS.ByteString]
idToPayload Nothing     = [ NTI.encodeInt32 (0 :: Int) ]
idToPayload (Just lpid) = [ NTI.encodeInt32 (1 :: Int)
                          , NTI.encodeInt32 (lpidCounter lpid)
                          , NTI.encodeInt32 (lpidUnique lpid)
                          ]

-- | Inverse of 'idToPayload'
payloadToId :: [BSS.ByteString] -> Maybe LocalProcessId
payloadToId bss = let (bs1, bss') = BSS.splitAt 4 . BSS.concat $ bss
                      (bs2, bs3)  = BSS.splitAt 4 bss' in
                  case NTI.decodeInt32 bs1 :: Int of
                    0 -> Nothing
                    1 -> Just LocalProcessId 
                           { lpidCounter = NTI.decodeInt32 bs2
                           , lpidUnique  = NTI.decodeInt32 bs3
                           }
                    _ -> fail "payloadToId"

instance Binary LocalProcessId where
  put lpid = put (lpidUnique lpid) >> put (lpidCounter lpid)
  get      = LocalProcessId <$> get <*> get

instance Binary ProcessId where
  put pid = put (processNodeId pid) >> put (processLocalId pid)
  get     = ProcessId <$> get <*> get

instance Binary MonitorNotification where
  put (MonitorNotification ref pid reason) = put ref >> put pid >> put reason
  get = MonitorNotification <$> get <*> get <*> get

instance Binary NCMsg where
  put msg = put (ctrlMsgSender msg) >> put (ctrlMsgSignal msg)
  get     = NCMsg <$> get <*> get

instance Binary MonitorRef where
  put ref = put (monitorRefPid ref) >> put (monitorRefCounter ref)
  get     = MonitorRef <$> get <*> get

instance Binary ProcessSignal where
  put (Link pid)        = putWord8 0 >> put pid
  put (Unlink pid)      = putWord8 1 >> put pid
  put (Monitor pid ref) = putWord8 2 >> put pid >> put ref
  put (Unmonitor ref)   = putWord8 3 >> put ref 
  put (Died who reason) = putWord8 4 >> put who >> put reason
  get = do
    header <- getWord8
    case header of
      0 -> Link <$> get
      1 -> Unlink <$> get
      2 -> Monitor <$> get <*> get
      3 -> Unmonitor <$> get
      4 -> Died <$> get <*> get
      _ -> fail "ProcessSignal.get: invalid"

instance Binary DiedReason where
  put DiedNormal        = putWord8 0
  put (DiedException e) = putWord8 1 >> put e 
  put DiedDisconnect    = putWord8 2
  put DiedNodeDown      = putWord8 3
  put DiedNoProc        = putWord8 4
  get = do
    header <- getWord8
    case header of
      0 -> return DiedNormal
      1 -> DiedException <$> get
      2 -> return DiedDisconnect
      3 -> return DiedNodeDown
      4 -> return DiedNoProc
      _ -> fail "DiedReason.get: invalid"

--------------------------------------------------------------------------------
-- Accessors                                                                  --
--------------------------------------------------------------------------------

localProcesses :: Accessor LocalNodeState (Map LocalProcessId LocalProcess)
localProcesses = accessor _localProcesses (\procs st -> st { _localProcesses = procs })

localPidCounter :: Accessor LocalNodeState Int32
localPidCounter = accessor _localPidCounter (\ctr st -> st { _localPidCounter = ctr })

localPidUnique :: Accessor LocalNodeState Int32
localPidUnique = accessor _localPidUnique (\unq st -> st { _localPidUnique = unq })

localMonitorCounter :: Accessor LocalNodeState Int32
localMonitorCounter = accessor _localMonitorCounter (\ctr st -> st { _localMonitorCounter = ctr }) 

localProcessWithId :: LocalProcessId -> Accessor LocalNodeState (Maybe LocalProcess)
localProcessWithId lpid = localProcesses >>> DAC.mapMaybe lpid

connections :: Accessor LocalProcessState (Map ProcessId NT.Connection)
connections = accessor _connections (\conns st -> st { _connections = conns })

connectionTo :: ProcessId -> Accessor LocalProcessState (Maybe NT.Connection)
connectionTo pid = connections >>> DAC.mapMaybe pid
