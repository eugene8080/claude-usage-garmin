// Generates golden vectors for the Kotlin port by running Orca's OWN v2 E2EE source
// (copied verbatim into ./shared from stablyai/orca src/shared) with tweetnacl.
import nacl from 'tweetnacl'
import { PairedE2EEV2ClientSession } from './shared/paired-e2ee-v2-client-session'
import { derivePairedE2EEV2KeySchedule } from './shared/paired-e2ee-v2-key-schedule'
import { encodeMobileE2EEV2Transcript, validateMobileE2EEV2Handshake } from './shared/mobile-e2ee-v2-contract'
import { sealMobileE2EEV2Frame } from './shared/mobile-e2ee-v2-framing'
import type { PairedE2EEPrimitives } from './shared/paired-e2ee-primitives'

const b64 = (u: Uint8Array) => Buffer.from(u).toString('base64')
const unb64 = (s: string) => new Uint8Array(Buffer.from(s, 'base64'))
const hex = (u: Uint8Array) => Buffer.from(u).toString('hex')
const fill = (n: number) => new Uint8Array(32).fill(n)

const primitives: PairedE2EEPrimitives = {
  generateKeyPair: () => nacl.box.keyPair(),
  deriveSharedKey: (sk, pk) => nacl.box.before(pk, sk),
  randomBytes: (n) => nacl.randomBytes(n),
  encodeBase64: b64,
  decodeBase64: unb64,
  publicKeyFromBase64: unb64,
  publicKeyToBase64: b64,
  sealLegacyText: () => { throw new Error('unused') },
  openLegacyText: () => null,
  sealLegacyBinary: () => { throw new Error('unused') },
  openLegacyBinary: () => null,
  deriveV2KeySchedule: derivePairedE2EEV2KeySchedule
}

// Fixed key material so every value below is reproducible.
const client = nacl.box.keyPair.fromSecretKey(fill(0x11))
const desktop = nacl.box.keyPair.fromSecretKey(fill(0x22))
const clientNonce = fill(0x33)
const desktopNonce = fill(0x44)
const deviceToken = 'test-device-token-0123456789'

const session = PairedE2EEV2ClientSession.create({
  primitives,
  desktopPublicKeyB64: b64(desktop.publicKey),
  transport: 'direct',
  clientNonce,
  clientKeyPair: client
})
const ready = {
  type: 'e2ee_ready',
  v: 2,
  desktopPublicKeyB64: b64(desktop.publicKey),
  clientNonceB64: b64(clientNonce),
  desktopNonceB64: b64(desktopNonce),
  selection: { framing: 2, payloadKinds: ['text', 'binary'] },
  context: session.hello.context
}
if (!session.acceptReady(ready)) throw new Error('ready rejected')

const handshake = validateMobileE2EEV2Handshake(session.hello, ready)!
const transcript = encodeMobileE2EEV2Transcript(handshake)
const schedule = derivePairedE2EEV2KeySchedule({
  sharedSecret: nacl.box.before(desktop.publicKey, client.secretKey),
  transcript,
  clientNonce,
  desktopNonce
})

const authPlain = JSON.stringify({
  type: 'e2ee_auth',
  v: 2,
  transcriptHashB64: session.transcriptHashB64,
  deviceToken
})
const authFrame = session.sealText(authPlain) // counter 0, mobile->desktop
const requestPlain = JSON.stringify({
  id: 'rpc-1',
  deviceToken,
  method: 'accounts.list',
  params: { refreshUsage: true }
})
const requestFrame = session.sealText(requestPlain) // counter 1

const desktopSeal = (plain: string, counter: bigint) =>
  b64(
    sealMobileE2EEV2Frame({
      payload: new TextEncoder().encode(plain),
      key: schedule.desktopToMobileKey,
      sessionId: schedule.sessionId,
      direction: 'desktop-to-mobile',
      payloadKind: 'text',
      counter
    })
  )
const authenticatedPlain = JSON.stringify({
  type: 'e2ee_authenticated',
  v: 2,
  transcriptHashB64: session.transcriptHashB64
})
const responsePlain = JSON.stringify({ id: 'rpc-1', ok: true, result: { hello: 'world' } })
const authenticatedFrame = desktopSeal(authenticatedPlain, 0n)
const responseFrame = desktopSeal(responsePlain, 1n)
// Round-trip through the client's own open, as the mobile app would.
if (session.openText(authenticatedFrame) !== authenticatedPlain) throw new Error('open 0 failed')
if (session.openText(responseFrame) !== responsePlain) throw new Error('open 1 failed')

// Raw NaCl primitive vectors.
const secretboxKey = fill(0x55)
const secretboxNonce = new Uint8Array(24).fill(0x66)
const secretboxMessage = new TextEncoder().encode('orca secretbox vector')

console.log(
  JSON.stringify(
    {
      clientSecretKeyHex: hex(client.secretKey),
      clientPublicKeyB64: b64(client.publicKey),
      desktopSecretKeyHex: hex(desktop.secretKey),
      desktopPublicKeyB64: b64(desktop.publicKey),
      clientNonceB64: b64(clientNonce),
      desktopNonceB64: b64(desktopNonce),
      x25519SharedHex: hex(nacl.scalarMult(client.secretKey, desktop.publicKey)),
      boxBeforeHex: hex(nacl.box.before(desktop.publicKey, client.secretKey)),
      secretboxKeyHex: hex(secretboxKey),
      secretboxNonceHex: hex(secretboxNonce),
      secretboxMessage: 'orca secretbox vector',
      secretboxHex: hex(nacl.secretbox(secretboxMessage, secretboxNonce, secretboxKey)),
      helloJson: JSON.stringify(session.hello),
      readyJson: JSON.stringify(ready),
      transcriptLength: transcript.length,
      transcriptHex: hex(transcript),
      transcriptHashB64: session.transcriptHashB64,
      mobileToDesktopKeyHex: hex(schedule.mobileToDesktopKey),
      desktopToMobileKeyHex: hex(schedule.desktopToMobileKey),
      sessionIdHex: hex(schedule.sessionId),
      deviceToken,
      authPlain,
      authFrameB64: authFrame,
      requestPlain,
      requestFrameB64: requestFrame,
      authenticatedPlain,
      authenticatedFrameB64: authenticatedFrame,
      responsePlain,
      responseFrameB64: responseFrame
    },
    null,
    2
  )
)
