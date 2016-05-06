{-# LANGUAGE RecordWildCards #-}

module Hans.Nat.Forward ( tryForwardUdp, tryForwardTcp ) where

import Hans.Addr.Types (Addr)
import Hans.Lens (view)
import Hans.Network (lookupRoute,RouteInfo(..))
import Hans.Tcp.Packet (TcpHeader(..),tcpSyn,tcpFin)
import Hans.Types
import Hans.Udp.Packet (UdpHeader(..))

import Control.Monad (when)
import Data.Time.Clock (getCurrentTime)
import Data.IORef (newIORef,readIORef,atomicWriteIORef)


-- TCP -------------------------------------------------------------------------

-- | Try to produce a new TCP packet that should be forwarded. Returns 'Nothing'
-- if the packet was destined for the local machine.
tryForwardTcp :: NetworkStack
              -> Addr -- ^ Local addr
              -> Addr -- ^ Remote addr
              -> TcpHeader
              -> IO (Maybe (RouteInfo Addr,Addr,TcpHeader))
tryForwardTcp ns local remote hdr =
  do let key = Flow local (tcpDestPort hdr) remote (tcpSourcePort hdr)
     mbEntry <- tcpForwardingActive ns key
     case mbEntry of

       -- forwarding is already established, rewrite the packet
       Just entry ->
         do when (view tcpFin hdr) $
              do now <- readIORef (tsLastMessage entry)
                 atomicWriteIORef (tsFinAt entry) (Just now)

            return $! rewrite key entry

       -- No forwarding entry exists. If it's a syn packet and there's a rule, start a
       -- new session.
       Nothing
         | view tcpSyn hdr ->
           do mbRule <- shouldForwardTcp ns key
              case mbRule of
                Nothing -> return Nothing

                -- add an entry to the table, and rewrite the packet
                Just rule ->
                  do mbSess <- newTcpSession ns key rule
                     case mbSess of
                       Just entry -> do addTcpSession ns entry
                                        return $! rewrite key entry

                       Nothing -> return Nothing

         | otherwise ->
           return Nothing

  where

  -- rewrite the source and destination in the header
  rewrite key entry =
    let other = otherSide key entry
        hdr'  = hdr { tcpSourcePort = flowLocalPort  other
                    , tcpDestPort   = flowRemotePort other }

     in hdr' `seq` Just (flowLocal other, flowRemote other, hdr')


-- | Generate a new TcpSession, given a flow that terminates on a port that is
-- being forwarded.
newTcpSession :: NetworkStack -> Flow Addr -> PortForward -> IO (Maybe TcpSession)
newTcpSession ns flow rule =
  do tsFinAt       <- newIORef Nothing
     tsLastMessage <- newIORef =<< getCurrentTime

     l <- lookupRoute ns (flowRemote flow)
     r <- lookupRoute ns (pfDestAddr rule)
     p <- nextTcpPort ns (flowLocal flow) (pfDestAddr rule) (pfDestPort rule)
     case (l,r,p) of
       (Just riLeft, Just riRight, Just rightPort) ->
         return $ Just
                $ TcpSession { tsLeft  = flow { flowLocal = riLeft }
                             , tsRight = Flow { flowLocal      = riRight
                                              , flowLocalPort  = rightPort
                                              , flowRemote     = pfDestAddr rule
                                              , flowRemotePort = pfDestPort rule }
                             , .. }

       _ -> return Nothing


-- UDP -------------------------------------------------------------------------

-- | Try to produce a new TCP packet that should be forwarded. Returns 'Nothing'
-- if the packet was destined for the local machine.
tryForwardUdp :: NetworkStack
              -> Addr -- ^ Local addr
              -> Addr -- ^ Remote addr
              -> UdpHeader
              -> IO (Maybe (RouteInfo Addr,Addr,UdpHeader))
tryForwardUdp ns local remote hdr =
  do let key = Flow local (udpDestPort hdr) remote (udpSourcePort hdr)
     mbEntry <- udpForwardingActive ns key
     case mbEntry of

       -- forwarding is already established, rewrite the packet
       Just entry -> return $! rewrite key entry

       -- No forwarding entry exists. If a rule exists, add it to the table.
       Nothing ->
         do mbRule <- shouldForwardUdp ns key
            case mbRule of

              Nothing -> return Nothing

              -- add an entry to the table, and rewrite the packet
              Just rule ->
                do mbSess <- newUdpSession ns key rule
                   case mbSess of
                     Just entry -> do addUdpSession ns entry
                                      return $! rewrite key entry
                     Nothing    -> return Nothing

  where

  rewrite key entry =
    let other = otherSide key entry
        hdr' = hdr { udpSourcePort = flowLocalPort  other
                   , udpDestPort   = flowRemotePort other }

     in hdr' `seq` Just (flowLocal other, flowRemote other, hdr')


newUdpSession :: NetworkStack -> Flow Addr -> PortForward -> IO (Maybe UdpSession)
newUdpSession ns flow rule =
  do usLastMessage <- newIORef =<< getCurrentTime

     l <- lookupRoute ns (flowRemote flow)
     r <- lookupRoute ns (pfDestAddr rule)
     p <- nextTcpPort ns (flowLocal flow) (pfDestAddr rule) (pfDestPort rule)

     case (l,r,p) of
       (Just riLeft, Just riRight, Just rightPort) ->
         return $ Just
                $ UdpSession { usLeft  = flow { flowLocal = riLeft }
                             , usRight = Flow { flowLocal      = riRight
                                              , flowLocalPort  = rightPort
                                              , flowRemote     = pfDestAddr rule
                                              , flowRemotePort = pfDestPort rule }
                             , .. }

       _ -> return Nothing
