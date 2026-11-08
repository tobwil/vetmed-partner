package de.tobwil.vetmed.core

import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.TestScope
import kotlinx.coroutines.test.advanceUntilIdle
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.time.Instant
import java.util.Base64

/** Voice mode protocol (ADR 0016) against a fake connection; no network, no audio hardware. */
@OptIn(ExperimentalCoroutinesApi::class)
class GeminiLiveTests {
    private val key = "synthetic-gemini-key-for-contract-tests"
    private fun json(text: String) = Json.parseToJsonElement(text).jsonObject

    @Test fun theOneTimeTokenIsCreatedWithTheKeyInTheHeaderAndLockedToTheModel() {
        val request = GeminiLive.tokenRequest(key, Instant.parse("2026-11-08T10:00:00Z"))
        assertEquals("https://generativelanguage.googleapis.com/v1beta/auth_tokens", request.url)
        assertEquals(key, request.headers["x-goog-api-key"])
        val body = request.body!!.decodeToString()
        assertFalse(body.contains(key))
        val root = json(body)
        assertEquals("1", root.getValue("uses").jsonPrimitive.content)
        assertEquals("2026-11-08T10:30:00Z", root.getValue("expireTime").jsonPrimitive.content)
        assertEquals("2026-11-08T10:01:00Z", root.getValue("newSessionExpireTime").jsonPrimitive.content)
        assertEquals("models/gemini-3.8-live", root.getValue("bidiGenerateContentSetup").jsonObject.getValue("model").jsonPrimitive.content)
        assertEquals("auth_tokens/abc", GeminiLive.token(HttpResponse(200, """{"name":"auth_tokens/abc"}""".encodeToByteArray())))
        listOf(HttpResponse(401, ByteArray(0)), HttpResponse(200, "{}".encodeToByteArray()), HttpResponse(200, """{"name":"a b"}""".encodeToByteArray())).forEach {
            try { GeminiLive.token(it); fail("expected failure") } catch (_: AppFailure) {}
        }
        assertTrue(GeminiLive.socketUrl("auth_tokens/a+b").endsWith("BidiGenerateContentConstrained?access_token=auth_tokens%2Fa%2Bb"))
    }

    @Test fun setupCarriesTheSparringRulesTranscriptionAndNoSearch() {
        val instructions = GeminiLive.instructions("# Rolle\nSparring.", "Laborbefund · Kreatinin 1,9")
        assertTrue(instructions.contains("Quellensuche: nicht aktiviert"))
        assertTrue(instructions.contains("# Sprachmodus"))
        // Found on a Pixel 9a: unclear audio made Gemini answer in French and Hindi.
        assertTrue(instructions.contains("SPRICH AUSSCHLIESSLICH DEUTSCH"))
        assertTrue(instructions.contains("Wechsle nie die Sprache"))
        assertTrue(instructions.endsWith("Laborbefund · Kreatinin 1,9"))
        assertFalse(GeminiLive.instructions("Basis", " ").contains("Fallkontext"))
        val setup = json(GeminiLive.setup(instructions, listOf("Meloxicam", "Meloxicam", " ", "Robenacoxib") + (1..200).map { "Begriff $it" })).getValue("setup").jsonObject
        assertEquals("models/gemini-3.8-live", setup.getValue("model").jsonPrimitive.content)
        assertEquals("AUDIO", setup.getValue("generationConfig").jsonObject.getValue("responseModalities").jsonArray.single().jsonPrimitive.content)
        assertEquals(instructions, setup.getValue("systemInstruction").jsonObject.getValue("parts").jsonArray.single().jsonObject.getValue("text").jsonPrimitive.content)
        val vocabulary = setup.getValue("inputAudioTranscription").jsonObject.getValue("customVocabulary").jsonArray.map { it.jsonPrimitive.content }
        assertEquals(100, vocabulary.size)
        assertEquals(listOf("Meloxicam", "Robenacoxib"), vocabulary.take(2))
        assertTrue(setup.containsKey("outputAudioTranscription"))
        assertTrue(setup.getValue("contextWindowCompression").jsonObject.containsKey("slidingWindow"))
        assertFalse(setup.containsKey("tools"))
        assertTrue(setup.getValue("sessionResumption").jsonObject.isEmpty())
        assertEquals("h1", json(GeminiLive.setup("x", emptyList(), "h1")).getValue("setup").jsonObject.getValue("sessionResumption").jsonObject.getValue("handle").jsonPrimitive.content)
        assertFalse(json(GeminiLive.setup("x", emptyList())).getValue("setup").jsonObject.getValue("inputAudioTranscription").jsonObject.containsKey("customVocabulary"))
    }

    @Test fun clientMessagesUseTheRealtimeInputShape() {
        val audio = json(GeminiLive.audio(byteArrayOf(1, 2, 3))).getValue("realtimeInput").jsonObject.getValue("audio").jsonObject
        assertEquals("audio/pcm;rate=16000", audio.getValue("mimeType").jsonPrimitive.content)
        assertEquals(Base64.getEncoder().encodeToString(byteArrayOf(1, 2, 3)), audio.getValue("data").jsonPrimitive.content)
        assertEquals("true", json(GeminiLive.audioStreamEnd()).getValue("realtimeInput").jsonObject.getValue("audioStreamEnd").jsonPrimitive.content)
        assertEquals("image/jpeg", json(GeminiLive.image(byteArrayOf(9))).getValue("realtimeInput").jsonObject.getValue("video").jsonObject.getValue("mimeType").jsonPrimitive.content)
    }

    private fun audio(vararg bytes: Byte) = """{"serverContent":{"modelTurn":{"parts":[{"inlineData":{"mimeType":"audio/pcm;rate=24000","data":"${Base64.getEncoder().encodeToString(bytes)}"}}]}}}"""

    @Test fun serverMessagesBecomeEvents() {
        assertEquals(listOf(GeminiLive.Event.SetupComplete), GeminiLive.parse("""{"setupComplete":{}}"""))
        val events = GeminiLive.parse("""{"serverContent":{"inputTranscription":{"text":"Hund"},"outputTranscription":{"text":"Ja"},"modelTurn":{"parts":[{"inlineData":{"mimeType":"audio/pcm;rate=24000","data":"AQI="}},{"text":"ignoriert"}]},"interrupted":true,"turnComplete":true}}""")
        assertEquals(GeminiLive.Event.InputText("Hund"), events[0])
        assertTrue((events[1] as GeminiLive.Event.Audio).pcm.contentEquals(byteArrayOf(1, 2)))
        assertEquals(listOf(GeminiLive.Event.OutputText("Ja"), GeminiLive.Event.Interrupted, GeminiLive.Event.TurnComplete), events.drop(2))
        assertEquals(listOf(GeminiLive.Event.GoAway(30.0)), GeminiLive.parse("""{"goAway":{"timeLeft":"30s"}}"""))
        assertEquals(listOf(GeminiLive.Event.Resumption("h2", true)), GeminiLive.parse("""{"sessionResumptionUpdate":{"newHandle":"h2","resumable":true}}"""))
        assertEquals(listOf(GeminiLive.Event.Resumption(null, false)), GeminiLive.parse("""{"sessionResumptionUpdate":{"newHandle":"","resumable":false}}"""))
        assertEquals(listOf(GeminiLive.Event.Usage(10, 20)), GeminiLive.parse("""{"usageMetadata":{"promptTokenCount":10,"responseTokenCount":20}}"""))
        assertTrue(GeminiLive.parse("kein json").single() is GeminiLive.Event.Failure)
        assertEquals(emptyList<GeminiLive.Event>(), GeminiLive.parse("""{"voiceActivity":{"type":"ACTIVITY_START"}}"""))
    }

    @Test fun theTranscriptJoinsChunksAndMarksInterruptions() {
        var turns = emptyList<LiveTurn>()
        listOf(GeminiLive.Event.InputText("Hund mit"), GeminiLive.Event.InputText(" Lahmheit"), GeminiLive.Event.InputText("."),
            GeminiLive.Event.OutputText("Seit wann"), GeminiLive.Event.OutputText("?"), GeminiLive.Event.TurnComplete,
            GeminiLive.Event.InputText("Seit gestern"), GeminiLive.Event.OutputText("Dann zuerst"), GeminiLive.Event.Interrupted,
        ).forEach { turns = LiveTranscript.apply(turns, it) }
        assertEquals(listOf("Hund mit Lahmheit.", "Seit wann?", "Seit gestern", "Dann zuerst"), turns.map { it.text })
        assertEquals(listOf(true, false, true, false), turns.map { it.fromUser })
        assertTrue(turns.last().interrupted && turns.none { it.open })
        assertEquals("**Du:** Hund mit Lahmheit.\n\n**VetMed:** Seit wann?\n\n**Du:** Seit gestern\n\n**VetMed:** Dann zuerst _(unterbrochen)_", LiveTranscript.markdown(turns))
        assertEquals(0.023, GeminiLive.costUSD(60.0, 60.0), 1e-9)
    }

    /** A connection that records what the session sends and lets the test play the server. */
    private class FakeServer : LiveConnector {
        val urls = mutableListOf<String>()
        val sockets = mutableListOf<Socket>()
        inner class Socket(val listener: LiveSocketListener) : LiveSocket {
            val sent = mutableListOf<String>(); var closed = false
            override fun send(text: String): Boolean { if (closed) return false; sent += text; return true }
            override fun close() { closed = true }
        }
        override fun connect(url: String, listener: LiveSocketListener): LiveSocket = Socket(listener).also { urls += url; sockets += it; listener.onOpen() }
    }

    private fun tokens(): Pair<HttpTransport, MutableList<HttpRequest>> {
        val requests = mutableListOf<HttpRequest>()
        return HttpTransport { request -> requests += request; HttpResponse(200, """{"name":"auth_tokens/t${requests.size}"}""".encodeToByteArray()) } to requests
    }

    @Test fun aSessionConnectsStreamsAndResumesAfterGoAway() = runTest {
        val server = FakeServer()
        val (transport, requests) = tokens()
        val session = LiveSession(key, "Anweisungen", listOf("Meloxicam"), server, this, transport)
        val played = mutableListOf<ByteArray>(); var interruptions = 0
        session.onAudio = { played += it }; session.onInterrupted = { interruptions++ }
        session.start(); advanceUntilIdle()
        val first = server.sockets.single()
        assertTrue(server.urls.single().endsWith("access_token=auth_tokens%2Ft1"))
        assertEquals("Anweisungen", json(first.sent.single()).getValue("setup").jsonObject.getValue("systemInstruction").jsonObject.getValue("parts").jsonArray[0].jsonObject.getValue("text").jsonPrimitive.content)
        session.sendAudio(ByteArray(3200))
        assertEquals("Audio vor setupComplete wird verworfen", 1, first.sent.size)
        first.listener.onMessage("""{"setupComplete":{}}""")
        assertEquals(LiveState.Live, session.state.value)
        session.sendAudio(ByteArray(32_000))
        assertTrue(json(first.sent.last()).getValue("realtimeInput").jsonObject.containsKey("audio"))
        assertEquals(1.0, session.audioSeconds.value.first, 1e-9)
        first.listener.onMessage("""{"serverContent":{"inputTranscription":{"text":"Hund lahmt"}}}""")
        first.listener.onMessage(audio(1, 2, 3, 4))
        first.listener.onMessage("""{"serverContent":{"outputTranscription":{"text":"Seit wann?"},"turnComplete":true}}""")
        assertEquals(1, played.size)
        assertEquals(4 / 48_000.0, session.audioSeconds.value.second, 1e-9)
        first.listener.onMessage("""{"serverContent":{"interrupted":true}}""")
        assertEquals(1, interruptions)

        // Go-away with a resumption handle: a new token and connection resume the same conversation.
        first.listener.onMessage("""{"sessionResumptionUpdate":{"newHandle":"h1","resumable":true}}""")
        first.listener.onMessage("""{"goAway":{"timeLeft":"10s"}}""")
        assertEquals(LiveState.Resuming, session.state.value)
        advanceUntilIdle()
        assertEquals(2, requests.size)
        val second = server.sockets[1]
        assertTrue(first.closed)
        first.listener.onClosed(1000, "")
        assertEquals("h1", json(second.sent.single()).getValue("setup").jsonObject.getValue("sessionResumption").jsonObject.getValue("handle").jsonPrimitive.content)
        second.listener.onMessage("""{"setupComplete":{}}""")
        assertEquals(LiveState.Live, session.state.value)
        second.listener.onMessage("""{"serverContent":{"outputTranscription":{"text":"Weiter."},"turnComplete":true}}""")
        assertEquals(listOf("Hund lahmt", "Seit wann?", "Weiter."), session.turns.value.map { it.text })
        // Late messages from the old connection are ignored.
        first.listener.onMessage("""{"serverContent":{"outputTranscription":{"text":"alt"}}}""")
        assertEquals(3, session.turns.value.size)

        session.stop()
        assertEquals(LiveState.Ended(null), session.state.value)
        assertTrue(second.closed)
        session.sendAudio(ByteArray(10))
        assertEquals(1 + 0, second.sent.size)
    }

    @Test fun aLostConnectionEndsVisiblyAndNeverReconnectsByItself() = runTest {
        val server = FakeServer()
        val (transport, requests) = tokens()
        val session = LiveSession(key, "x", emptyList(), server, this, transport)
        session.start(); advanceUntilIdle()
        server.sockets.single().listener.onMessage("""{"setupComplete":{}}""")
        server.sockets.single().listener.onMessage("""{"serverContent":{"outputTranscription":{"text":"Ich hö"}}}""")
        server.sockets.single().listener.onFailure("reset")
        advanceUntilIdle()
        assertTrue((session.state.value as LiveState.Ended).message!!.contains("unterbrochen"))
        assertEquals(1, requests.size)
        assertEquals(1, server.sockets.size)
        assertFalse(session.turns.value.single().open)
        // Without a resumption handle a go-away cannot resume: the session ends when the server closes.
        val server2 = FakeServer()
        val other = LiveSession(key, "x", emptyList(), server2, this, transport)
        other.start(); advanceUntilIdle()
        server2.sockets.single().listener.onMessage("""{"setupComplete":{}}""")
        server2.sockets.single().listener.onMessage("""{"goAway":{"timeLeft":"5s"}}""")
        advanceUntilIdle()
        assertEquals(LiveState.Live, other.state.value)
        assertEquals(1, server2.sockets.size)
        server2.sockets.single().listener.onClosed(1001, "going away")
        assertTrue(other.state.value is LiveState.Ended)
    }

    @Test fun aRefusedTokenEndsTheSessionWithTheProviderMessage() = runTest {
        val session = LiveSession(key, "x", emptyList(), FakeServer(), this, HttpTransport { HttpResponse(403, ByteArray(0)) })
        session.start(); advanceUntilIdle()
        assertTrue((session.state.value as LiveState.Ended).message!!.contains("abgewiesen"))
    }

    @Test fun interruptingLocallyDropsTheRestOfTheAnswer() = runTest {
        val server = FakeServer()
        val session = LiveSession(key, "x", emptyList(), server, this, tokens().first)
        val played = mutableListOf<ByteArray>(); var stops = 0
        session.onAudio = { played += it }; session.onInterrupted = { stops++ }
        session.start(); advanceUntilIdle()
        val socket = server.sockets.single()
        socket.listener.onMessage("""{"setupComplete":{}}""")
        socket.listener.onMessage(audio(1, 2))
        socket.listener.onMessage("""{"serverContent":{"outputTranscription":{"text":"Lange Antwort"}}}""")
        session.interrupt()
        socket.listener.onMessage(audio(3, 4))
        assertEquals(1, played.size)
        assertEquals(1, stops)
        assertTrue(session.turns.value.last().interrupted)
        socket.listener.onMessage("""{"serverContent":{"turnComplete":true}}""")
        socket.listener.onMessage(audio(5, 6))
        assertEquals(2, played.size)
        session.pauseInput()
        assertTrue(json(socket.sent.last()).getValue("realtimeInput").jsonObject.containsKey("audioStreamEnd"))
        assertTrue(session.sendImage(byteArrayOf(1)))
    }
}
