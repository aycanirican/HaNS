{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE MultiWayIf #-}

module Hans.Tcp.SendWindow (
    -- * Remote Window
    Window(),
    emptyWindow,
    sndNxt, setSndNxt,
    sndUna,
    sndWnd,
    nullWindow,
    flushWindow,

    -- ** Timestamp Clock
    TSClock(),
    initialTSClock,
    updateTSClock,
    tsVal,

    -- ** Packet Processing
    queueSegment,
    retransmitTimeout,
    ackSegment,

    -- ** Selective Ack
    handleSack,
  ) where

import Hans.Config
import Hans.Lens
import Hans.Tcp.Packet

import           Control.Monad (guard)
import qualified Data.ByteString.Lazy as L
import           Data.List (sortBy)
import           Data.Maybe (isJust)
import           Data.Ord (comparing)
import           Data.Time.Clock (UTCTime,NominalDiffTime,diffUTCTime)
import           Data.Word (Word32)


-- Segments --------------------------------------------------------------------

data Segment = Segment { segHeader    :: !TcpHeader
                       , segRightEdge :: !TcpSeqNum -- ^ Cached right edge
                       , segBody      :: !L.ByteString
                       , segSentAt    :: !(Maybe UTCTime)
                       , segSACK      :: !Bool
                       }

segHeaderL :: Lens' Segment TcpHeader
segHeaderL f Segment { .. } =
  fmap (\h -> Segment { segHeader = h, .. }) (f segHeader)

instance HasTcpOptions Segment where
  tcpOptions = segHeaderL . tcpOptions

mkSegment :: TcpHeader -> L.ByteString -> UTCTime -> Segment
mkSegment segHeader segBody now  =
  Segment { segRightEdge = tcpSegNextAckNum segHeader (fromIntegral (L.length segBody))
          , segSACK      = False
          , segSentAt    = Just now
          , .. }

-- | The sequence number of the frame.
--
-- INVARIANT: the sequence number must always be greater than or equal to the
-- current sequence number, and less than the value of the right edge of the
-- segment.
leftEdge :: Lens' Segment TcpSeqNum
leftEdge f seg@Segment { segHeader = hdr@TcpHeader { .. }, .. } =
  fmap update (f tcpSeqNum)
  where

  update sn
      -- only update if the sequence number can actually trim the packet
    | sn <= tcpSeqNum = seg
    | otherwise       =
      -- account syn counting for one
      let len = fromTcpSeqNum (sn - tcpSeqNum)
          (hdr',len') | view tcpSyn hdr = (set tcpSyn False hdr,len - 1)
                      | otherwise       = (hdr,len)

      -- NOTE: the header gets the unmodified sequence number, but the data gets
      -- the adjusted version, as the adjusted 
      in Segment { segHeader = hdr' { tcpSeqNum = sn } -- NOTE: use old sn here
                 , segBody   = L.drop len' segBody
                 , .. }
{-# INLINE leftEdge #-}


-- | The sequence number of the first byte AFTER this segment.
--
-- INVARIANT: the sequence number must always be less than or equal to the
-- current right edge sequence number, and greater than or equal to the left
-- edge.
rightEdge :: Getting r Segment TcpSeqNum
rightEdge  = to segRightEdge
{-# INLINE rightEdge #-}


-- | The SACK flag for this segment. This flag is turned TRUE when the segment
-- has been wholly acknowledged through the SACK option on an incoming ACK.
sack :: Lens' Segment Bool
sack f seg@Segment { .. } =
  fmap update (f segSACK)
  where
  update b | b == segSACK = seg
           | otherwise    = Segment { segSACK = b, .. }


-- Timestamp Clock -------------------------------------------------------------

data TSClock = TSClock { tscVal :: !Word32, tscLastUpdate :: !UTCTime }

-- | Create a 'TSClock'.
initialTSClock :: Word32 -> UTCTime -> TSClock
initialTSClock tscVal tscLastUpdate = TSClock { .. }

-- | Update the timestamp clock, and return the new value of TSval.
updateTSClock :: Config -> UTCTime -> TSClock -> TSClock
updateTSClock Config { .. } now TSClock { .. } =
  let diff = truncate (diffUTCTime now tscLastUpdate * cfgTcpTSClockFrequency)
   in TSClock { tscVal = tscVal + diff, tscLastUpdate = now }

-- | The current value of the TS clock.
tsVal :: Getting r TSClock Word32
tsVal  = to tscVal

-- | Given an echo'd timestamp, generate an RTT measurement.
measureRTT :: Config -> Word32 -> TSClock -> NominalDiffTime
measureRTT Config { .. } ecr clk =
  fromIntegral (view tsVal clk - ecr) / cfgTcpTSClockFrequency


-- Send Window -----------------------------------------------------------------

type Segments = [Segment]

-- | This structure holds bookkeeping variables for the remote end's receive
-- window, as well as the retransmit queue.
data Window = Window { wRetransmitQueue :: !Segments
                       -- ^ The retransmit queue contains segments that fall
                       -- between SND.UNA and SND.NXT

                     , wSndAvail        :: !Int
                       -- ^ The effective window

                     , wSndNxt          :: !TcpSeqNum
                     , wSndWnd          :: !TcpSeqNum

                     , wTSClock :: !TSClock
                     }


emptyWindow :: TcpSeqNum -- ^ SND.NXT
            -> TcpSeqNum -- ^ SND.WND
            -> TSClock
            -> Window
emptyWindow wSndNxt wSndWnd wTSClock =
  Window { wRetransmitQueue = []
         , wSndAvail        = fromTcpSeqNum wSndWnd
         , .. }


-- | Remove everything from the remote window.
flushWindow :: Window -> (Window, ())
flushWindow Window { .. } = (Window { wRetransmitQueue = [], .. }, ())


-- | True when the window is empty.
nullWindow :: Window -> Bool
nullWindow Window { .. } = null wRetransmitQueue

-- | The value of SND.NXT.
--
-- NOTE: SND.UNA <= SND.NXT < SND.UNA + SND.WND
sndNxt :: Getting r Window TcpSeqNum
sndNxt  = to wSndNxt


-- | Only sets the value of SND.NXT when the retransmit queue is empty.
setSndNxt :: TcpSeqNum -> Window -> (Window, Bool)
setSndNxt nxt win
  | null (wRetransmitQueue win) = (win { wSndNxt = nxt }, True)
  | otherwise                   = (win, False)


-- | The value of SND.WND.
sndWnd :: Lens' Window TcpSeqNum
sndWnd f Window { .. } =
  fmap (\ wnd -> Window { wSndWnd   = wnd
                        , wSndAvail = wSndAvail + fromTcpSeqNum (wnd - wSndWnd)
                        , .. })
       (f wSndWnd)


-- | The value of SND.UNA -- the left-edge of the send window.
sndUna :: Getting r Window TcpSeqNum
sndUna  = to $ \ Window { .. } ->
  case wRetransmitQueue of
    seg : _ -> view leftEdge seg
    []      -> wSndNxt


-- | Returns the new send window, as well as boolean indicating whether or not
-- the retransmit timer needs to be started.
queueSegment :: Config -> UTCTime -> (Word32 -> TcpSeqNum -> TcpHeader) -> L.ByteString
             -> Window -> (Window,Maybe (Bool,TcpHeader,L.ByteString))
queueSegment cfg now mkHdr body win
  | size == 0          = (win, Just (False,hdr,L.empty))
  | wSndAvail win == 0 = (win,Nothing)
  | otherwise          = (win',Just (startRTO,hdr,trimmedBody))
  where

  clock'      = updateTSClock cfg now (wTSClock win)
  hdr         = mkHdr (view tsVal clock') (wSndNxt win)

  trimmedBody = L.take (fromIntegral (wSndAvail win)) body
  seg         = mkSegment hdr trimmedBody now

  size        = tcpSegLen hdr (fromIntegral (L.length trimmedBody))

  win' = win { wRetransmitQueue = wRetransmitQueue win ++ [seg]
             , wSndAvail        = wSndAvail win - size
             , wSndNxt          = wSndNxt win + fromIntegral size
             , wTSClock         = clock'
             }

  -- start the retransmit timer when the queue was empty
  startRTO = null (wRetransmitQueue win)


-- | A retransmit timer has gone off: reset the sack bit on all segments in the
-- queue; if the left-edge exists, mark it as having been retransmitted, and
-- return it back to be sent.
--
-- XXX: does this need to update the TS clock?
retransmitTimeout :: Window -> (Window,Maybe (TcpHeader,L.ByteString))
retransmitTimeout win = (win { wRetransmitQueue = queue' }, mbSeg)
  where

  (mbSeg,queue') =
    case wRetransmitQueue win of
      Segment { .. } : rest ->
        ( Just (segHeader,segBody)
        , map (set sack False) (Segment { segSentAt = Nothing, .. } : rest ) )

      [] -> (Nothing,[])


-- | Remove all segments of the send window that occur before this sequence
-- number, and increase the size of the available window. When the segment
-- doesn't acknowledge anything in the window, 'Nothing' as the second
-- parameter. Otherwise, return a boolean that is 'True' when there are no
-- outstanding segments, and a measurement of the RTT when the segment has not
-- been retransmitted.
ackSegment :: Config -> UTCTime -> TcpSeqNum -> Window
           -> (Window, Maybe (Bool,Maybe NominalDiffTime))
ackSegment cfg now ack win
  | view sndUna win <= ack && ack <= view sndNxt win =
    ( win', Just (null (wRetransmitQueue win'), mbMeasurement) )

  | otherwise =
    ( win, Nothing )
  where
  win' = win { wRetransmitQueue = queue'
             , wSndAvail        = wSndAvail win + fromTcpSeqNum (ack - view sndUna win)
             , wTSClock         = updateTSClock cfg now (wTSClock win)
             }

  -- zip down the send queue, partitioning it into (reversed) acknowledged
  -- packets, and outstanding packets.
  go acks segs@(seg : rest)
    | view rightEdge seg <= ack = go (seg:acks) rest
    | view leftEdge  seg <= ack = (seg:acks, set leftEdge ack seg : rest)
    | otherwise                 = (acks,segs)

  go acks [] = (acks,[])

  -- partition packets that have been acknowledged
  (ackd,queue') = go [] (wRetransmitQueue win)

  -- generate a measurement. If the timestamp option is available, that will be
  -- used to generate the measurement, otherwise the sending time for the
  -- segment will be diffed if it's valid.
  mbMeasurement =
    case ackd of
      seg : _

        | Just (OptTimestamp val _) <- findTcpOption OptTagTimestamp seg ->
          return (measureRTT cfg val (wTSClock win'))

        | otherwise ->
          do let samples = filter (isJust . segSentAt) ackd
             guard (not (null samples))
             let Segment { .. } = last samples
             sent <- segSentAt
             return $! diffUTCTime sent now

      [] -> Nothing


-- Selective ACK ---------------------------------------------------------------

-- | Process a sack option, and return the updated window, and the segments that
-- are missing from the remote window.
handleSack :: [SackBlock] -> Window -> (Window,[(TcpHeader,L.ByteString)])
handleSack blocks win =
  let win' = processSackBlocks blocks win
   in (win', sackRetransmit win')

-- | All segments that have not been selectively acknowledged. This can be used
-- when replying to a duplicate ack that contains a SACK option, after the
-- option has been processed. NOTE: this still doesn't remove the packets from
-- the queue, it just means that we know what parts to retransmit.
sackRetransmit :: Window -> [(TcpHeader,L.ByteString)]
sackRetransmit Window { .. } =
  [ (segHeader,segBody) | Segment { .. } <- wRetransmitQueue, not segSACK ]


-- | Mark segments that have been acknowledged through the SACK option.
processSackBlocks :: [SackBlock] -> Window -> Window
processSackBlocks blocks Window { .. } =
  Window { wRetransmitQueue = go wRetransmitQueue (sortBy (comparing sbLeft) blocks)
         , .. }
  where

  go queue@(seg:segs) bs@(SackBlock { .. } :rest)

      -- segment falls within the block
    | segWithin seg sbLeft sbRight = set sack True seg : go segs bs

      -- segment begins after the block
    | view leftEdge seg >= sbRight = go queue rest

      -- segment ends before the block
    | otherwise = seg : go segs bs

  go segs _ = segs


-- | True when the segment falls wholly within the range given.
segWithin :: Segment -> TcpSeqNum -> TcpSeqNum -> Bool
segWithin seg l r = view leftEdge seg >= l && view rightEdge seg < r
  -- Remember that since SACK blocks define the right edge as being the first
  -- sequence number of the /next/ block, we use strict less-than for the
  -- comparison of the right edge.
