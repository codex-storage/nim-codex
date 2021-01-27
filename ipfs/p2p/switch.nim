import std/tables
import pkg/chronos
import pkg/libp2p/switch
import pkg/libp2p/crypto/crypto
import pkg/libp2p/peerinfo
import pkg/libp2p/protocols/identify
import pkg/libp2p/stream/connection
import pkg/libp2p/muxers/muxer
import pkg/libp2p/muxers/mplex/mplex
import pkg/libp2p/transports/transport
import pkg/libp2p/transports/tcptransport
import pkg/libp2p/protocols/secure/secure
import pkg/libp2p/protocols/secure/noise
import pkg/libp2p/protocols/secure/secio
import ./rng

export switch

proc create*(t: type Switch): Switch =

  proc createMplex(conn: Connection): Muxer =
    Mplex.init(conn)

  let privateKey = PrivateKey.random(Ed25519, Rng.instance[]).get()
  let peerInfo = PeerInfo.init(privateKey)
  let identify = newIdentify(peerInfo)
  let mplexProvider = newMuxerProvider(createMplex, MplexCodec)
  let transports = @[Transport(TcpTransport.init({ReuseAddr}))]
  let muxers = [(MplexCodec, mplexProvider)].toTable
  let secureManagers = [Secure(newNoise(Rng.instance, privateKey))]

  newSwitch(peerInfo, transports, identify, muxers, secureManagers)
