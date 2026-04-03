package com.example.assistantapp

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Bundle
import android.speech.tts.TextToSpeech
import android.util.Log
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import org.json.JSONObject
import org.vosk.Model
import org.vosk.Recognizer
import org.vosk.android.RecognitionListener
import org.vosk.android.SpeechService
import java.io.File
import java.io.FileOutputStream
import java.util.Locale
import kotlin.math.roundToInt

class MainActivity : FlutterActivity(), TextToSpeech.OnInitListener {

    private val TTS_CHANNEL = "assistantapp/tts"
    private val SPEECH_CHANNEL = "assistantapp/speech"
    private val ORIENTATION_CHANNEL = "odin/orientation_stream"

    private val REQ_RECORD_AUDIO = 1001

    private var tts: TextToSpeech? = null
    private var ttsReady = false

    private var speechChannel: MethodChannel? = null

    private var voskModel: Model? = null
    private var recognizer: Recognizer? = null
    private var speechService: SpeechService? = null

    private var pendingStartAfterPermission = false
    private var isModelReady = false
    private var isListening = false
    private var finalDelivered = false

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        tts = TextToSpeech(this, this)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            TTS_CHANNEL
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "init" -> result.success(true)

                "speak" -> {
                    val text = call.argument<String>("text") ?: ""
                    if (ttsReady && text.isNotBlank()) {
                        tts?.speak(text, TextToSpeech.QUEUE_FLUSH, null, "assistantUtterance")
                        result.success(true)
                    } else {
                        result.error("TTS_NOT_READY", "TextToSpeech non pronto", null)
                    }
                }

                "stop" -> {
                    tts?.stop()
                    result.success(true)
                }

                "dispose" -> {
                    tts?.stop()
                    tts?.shutdown()
                    result.success(true)
                }

                else -> result.notImplemented()
            }
        }

        speechChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            SPEECH_CHANNEL
        )

        speechChannel!!.setMethodCallHandler { call, result ->
            when (call.method) {
                "startListening" -> {
                    startVoskRecognition()
                    result.success(true)
                }

                "stopListening" -> {
                    stopVoskRecognition()
                    result.success(true)
                }

                "disposeSpeech" -> {
                    disposeVoskRecognition()
                    result.success(true)
                }

                else -> result.notImplemented()
            }
        }

        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            ORIENTATION_CHANNEL
        ).setStreamHandler(OrientationStreamHandler(this))

        initVoskModel()
    }

    private fun initVoskModel() {
        if (isModelReady || voskModel != null) return

        try {
            speechChannel?.invokeMethod("onPartial", "Copia modello offline...")

            val modelDir = File(filesDir, "vosk-model-it")
            if (!modelDir.exists() || modelDir.listFiles().isNullOrEmpty()) {
                copyAssetFolder("model", modelDir)
            }

            speechChannel?.invokeMethod("onPartial", "Caricamento modello offline...")
            voskModel = Model(modelDir.absolutePath)
            isModelReady = true
            speechChannel?.invokeMethod("onPartial", "Modello offline pronto")
        } catch (e: Exception) {
            isModelReady = false
            speechChannel?.invokeMethod(
                "onFinal",
                "Errore caricamento modello: ${e.message ?: "sconosciuto"}"
            )
        }
    }

    private fun copyAssetFolder(assetPath: String, destDir: File) {
        val assetManager = assets
        val files = assetManager.list(assetPath) ?: emptyArray()

        if (files.isEmpty()) {
            copyAssetFile(assetPath, destDir)
            return
        }

        if (!destDir.exists()) {
            destDir.mkdirs()
        }

        for (file in files) {
            val childAssetPath = "$assetPath/$file"
            val childFiles = assetManager.list(childAssetPath) ?: emptyArray()

            if (childFiles.isEmpty()) {
                copyAssetFile(childAssetPath, File(destDir, file))
            } else {
                copyAssetFolder(childAssetPath, File(destDir, file))
            }
        }
    }

    private fun copyAssetFile(assetPath: String, destFile: File) {
        destFile.parentFile?.mkdirs()
        assets.open(assetPath).use { input ->
            FileOutputStream(destFile).use { output ->
                input.copyTo(output)
            }
        }
    }

    private fun hasAudioPermission(): Boolean {
        return ContextCompat.checkSelfPermission(
            this,
            Manifest.permission.RECORD_AUDIO
        ) == PackageManager.PERMISSION_GRANTED
    }

    private fun requestAudioPermission() {
        ActivityCompat.requestPermissions(
            this,
            arrayOf(Manifest.permission.RECORD_AUDIO),
            REQ_RECORD_AUDIO
        )
    }

    private fun startVoskRecognition() {
        finalDelivered = false

        if (!hasAudioPermission()) {
            pendingStartAfterPermission = true
            requestAudioPermission()
            speechChannel?.invokeMethod("onPartial", "Richiesta permesso microfono...")
            return
        }

        if (!isModelReady || voskModel == null) {
            initVoskModel()
            if (!isModelReady || voskModel == null) {
                speechChannel?.invokeMethod("onFinal", "Modello non ancora pronto")
                return
            }
        }

        try {
            stopVoskRecognition()

            recognizer = Recognizer(voskModel, 16000.0f)
            speechService = SpeechService(recognizer, 16000.0f)
            speechService?.startListening(voskListener)
            isListening = true
            speechChannel?.invokeMethod("onPartial", "Pronto, parla pure")
        } catch (e: Exception) {
            isListening = false
            speechChannel?.invokeMethod(
                "onFinal",
                "Errore avvio Vosk: ${e.message ?: "sconosciuto"}"
            )
        }
    }

    private fun stopVoskRecognition() {
        try {
            speechService?.stop()
        } catch (_: Exception) {
        }

        try {
            speechService?.cancel()
        } catch (_: Exception) {
        }

        speechService = null

        try {
            recognizer?.close()
        } catch (_: Exception) {
        }

        recognizer = null
        isListening = false

        speechChannel?.invokeMethod("onPartial", "Ascolto fermato")
    }

    private fun disposeVoskRecognition() {
        stopVoskRecognition()

        try {
            voskModel?.close()
        } catch (_: Exception) {
        }

        voskModel = null
        isModelReady = false
    }

    private val voskListener = object : RecognitionListener {
        override fun onPartialResult(hypothesis: String?) {
            if (finalDelivered) return

            val text = extractTextFromVoskJson(hypothesis)
            if (text.isNotBlank()) {
                speechChannel?.invokeMethod("onPartial", text)
            }
        }

        override fun onResult(hypothesis: String?) {
            if (finalDelivered) return

            val text = extractTextFromVoskJson(hypothesis)
            if (text.isNotBlank()) {
                finalDelivered = true
                isListening = false
                speechChannel?.invokeMethod("onFinal", text)
            }
        }

        override fun onFinalResult(hypothesis: String?) {
            if (finalDelivered) return

            val text = extractTextFromVoskJson(hypothesis)
            finalDelivered = true
            isListening = false

            if (text.isNotBlank()) {
                speechChannel?.invokeMethod("onFinal", text)
            }
        }

        override fun onError(e: Exception?) {
            finalDelivered = true
            isListening = false
            speechChannel?.invokeMethod(
                "onFinal",
                "Errore Vosk: ${e?.message ?: "sconosciuto"}"
            )
        }

        override fun onTimeout() {
            finalDelivered = true
            isListening = false
            speechChannel?.invokeMethod("onFinal", "Timeout ascolto")
        }
    }

    private fun extractTextFromVoskJson(json: String?): String {
        if (json.isNullOrBlank()) return ""

        return try {
            val obj = JSONObject(json)
            when {
                obj.has("text") -> obj.optString("text", "").trim()
                obj.has("partial") -> obj.optString("partial", "").trim()
                else -> ""
            }
        } catch (_: Exception) {
            json.trim()
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)

        if (requestCode == REQ_RECORD_AUDIO) {
            val granted = grantResults.isNotEmpty() &&
                grantResults[0] == PackageManager.PERMISSION_GRANTED

            if (granted) {
                speechChannel?.invokeMethod("onPartial", "Permesso microfono concesso")
                if (pendingStartAfterPermission) {
                    pendingStartAfterPermission = false
                    startVoskRecognition()
                }
            } else {
                pendingStartAfterPermission = false
                speechChannel?.invokeMethod("onFinal", "Permesso microfono negato")
            }
        }
    }

    override fun onInit(status: Int) {
        if (status == TextToSpeech.SUCCESS) {
            val langResult = tts?.setLanguage(Locale.ITALIAN)
            ttsReady = langResult != TextToSpeech.LANG_MISSING_DATA &&
                langResult != TextToSpeech.LANG_NOT_SUPPORTED
        } else {
            ttsReady = false
        }
    }

    override fun onDestroy() {
        tts?.stop()
        tts?.shutdown()
        disposeVoskRecognition()
        super.onDestroy()
    }
}

class OrientationStreamHandler(
    context: Context
) : EventChannel.StreamHandler, SensorEventListener {

    private val sensorManager =
        context.getSystemService(Context.SENSOR_SERVICE) as SensorManager

    private val rotationVectorSensor: Sensor? =
        sensorManager.getDefaultSensor(Sensor.TYPE_ROTATION_VECTOR)

    private val accelerometerSensor: Sensor? =
        sensorManager.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)

    private val magnetometerSensor: Sensor? =
        sensorManager.getDefaultSensor(Sensor.TYPE_MAGNETIC_FIELD)

    private var eventSink: EventChannel.EventSink? = null

    private val rotationMatrix = FloatArray(9)
    private val remappedMatrix = FloatArray(9)
    private val orientationAngles = FloatArray(3)

    private var accelValues: FloatArray? = null
    private var magnetValues: FloatArray? = null

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events

        if (rotationVectorSensor != null) {
            sensorManager.registerListener(
                this,
                rotationVectorSensor,
                SensorManager.SENSOR_DELAY_GAME
            )
            Log.d("ODIN_ORIENTATION", "Usando TYPE_ROTATION_VECTOR")
        } else {
            accelerometerSensor?.let {
                sensorManager.registerListener(
                    this,
                    it,
                    SensorManager.SENSOR_DELAY_GAME
                )
            }

            magnetometerSensor?.let {
                sensorManager.registerListener(
                    this,
                    it,
                    SensorManager.SENSOR_DELAY_GAME
                )
            }

            Log.d("ODIN_ORIENTATION", "Fallback accelerometer + magnetometer")
        }
    }

    override fun onCancel(arguments: Any?) {
        sensorManager.unregisterListener(this)
        eventSink = null
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) {
    }

    override fun onSensorChanged(event: SensorEvent) {
        when (event.sensor.type) {
            Sensor.TYPE_ROTATION_VECTOR -> {
                SensorManager.getRotationMatrixFromVector(
                    rotationMatrix,
                    event.values
                )
                emitOrientationFromMatrix(rotationMatrix)
            }

            Sensor.TYPE_ACCELEROMETER -> {
                accelValues = event.values.clone()
                tryEmitFromAccelMag()
            }

            Sensor.TYPE_MAGNETIC_FIELD -> {
                magnetValues = event.values.clone()
                tryEmitFromAccelMag()
            }
        }
    }

    private fun tryEmitFromAccelMag() {
        val acc = accelValues ?: return
        val mag = magnetValues ?: return

        val success = SensorManager.getRotationMatrix(
            rotationMatrix,
            null,
            acc,
            mag
        )

        if (success) {
            emitOrientationFromMatrix(rotationMatrix)
        }
    }

    private fun emitOrientationFromMatrix(matrix: FloatArray) {
        SensorManager.remapCoordinateSystem(
            matrix,
            SensorManager.AXIS_X,
            SensorManager.AXIS_Z,
            remappedMatrix
        )

        SensorManager.getOrientation(remappedMatrix, orientationAngles)

        val yawDeg = Math.toDegrees(orientationAngles[0].toDouble())
        val pitchDeg = Math.toDegrees(orientationAngles[1].toDouble())
        val rollDeg = Math.toDegrees(orientationAngles[2].toDouble())

        val payload = mapOf(
            "yaw" to normalizeAngleDeg(yawDeg),
            "pitch" to normalizeAngleDeg(pitchDeg),
            "roll" to normalizeAngleDeg(rollDeg)
        )

        Log.d(
            "ODIN_ORIENTATION",
            "pitch=${payload["pitch"]} roll=${payload["roll"]} yaw=${payload["yaw"]}"
        )

        eventSink?.success(payload)
    }

    private fun normalizeAngleDeg(angle: Double): Double {
        var a = angle % 360.0
        if (a > 180.0) a -= 360.0
        if (a < -180.0) a += 360.0
        return ((a * 10.0).roundToInt() / 10.0)
    }
}
