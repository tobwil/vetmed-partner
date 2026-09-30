package de.tobwil.vetmed.data

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import de.tobwil.vetmed.core.AppFailure
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.security.GeneralSecurityException
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/** Supplies the AES-256 key for one sealed store. Android uses the hardware-backed Keystore. */
interface KeySource {
    fun existing(): SecretKey?
    fun create(): SecretKey
}

class AndroidKeystoreKeySource(private val alias: String) : KeySource {
    private val keyStore by lazy { KeyStore.getInstance("AndroidKeyStore").apply { load(null) } }
    override fun existing(): SecretKey? = (keyStore.getEntry(alias, null) as? KeyStore.SecretKeyEntry)?.secretKey
    override fun create(): SecretKey {
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        generator.init(
            KeyGenParameterSpec.Builder(alias, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .setRandomizedEncryptionRequired(true)
                .build(),
        )
        return generator.generateKey()
    }
}

/**
 * One AES-GCM sealed file: magic, 12-byte IV, ciphertext with tag. The context string is
 * authenticated, so a file cannot be swapped in for another purpose. Writes are atomic.
 */
class SealedFile(private val file: File, private val keys: KeySource, private val context: String) {
    private companion object {
        val MAGIC = byteArrayOf('V'.code.toByte(), 'M'.code.toByte(), 'S'.code.toByte(), 1)
        const val IV_BYTES = 12
        const val TAG_BITS = 128
    }

    val exists: Boolean get() = file.exists()

    fun read(): ByteArray? {
        if (!file.exists()) return null
        val key = keys.existing() ?: throw AppFailure("Der Schlüssel zu vorhandenen Daten fehlt. Daten werden nicht überschrieben.")
        val sealed = file.readBytes()
        if (sealed.size < MAGIC.size + IV_BYTES + TAG_BITS / 8 || !sealed.copyOfRange(0, MAGIC.size).contentEquals(MAGIC)) {
            throw AppFailure("Die verschlüsselten Daten sind beschädigt.")
        }
        return try {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(TAG_BITS, sealed, MAGIC.size, IV_BYTES))
            cipher.updateAAD(context.encodeToByteArray())
            cipher.doFinal(sealed, MAGIC.size + IV_BYTES, sealed.size - MAGIC.size - IV_BYTES)
        } catch (error: GeneralSecurityException) {
            throw AppFailure("Die verschlüsselten Daten konnten nicht geprüft werden. Sie werden nicht überschrieben.")
        }
    }

    fun write(plain: ByteArray) {
        val key = keys.existing() ?: if (file.exists()) {
            throw AppFailure("Der Schlüssel zu vorhandenen Daten fehlt. Daten werden nicht überschrieben.")
        } else keys.create()
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, key)
        cipher.updateAAD(context.encodeToByteArray())
        val body = cipher.doFinal(plain)
        val iv = cipher.iv
        check(iv.size == IV_BYTES)
        file.parentFile?.mkdirs()
        val temporary = File(file.parentFile, file.name + ".tmp")
        try {
            FileOutputStream(temporary).use { out ->
                out.write(MAGIC); out.write(iv); out.write(body)
                out.fd.sync()
            }
            Files.move(temporary.toPath(), file.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
        } catch (error: IOException) {
            temporary.delete()
            throw AppFailure(
                if (error.message?.contains("ENOSPC") == true || error.message?.contains("No space") == true)
                    "Der Gerätespeicher ist voll. Die letzte gespeicherte Fassung bleibt erhalten. Bitte Speicher freigeben und erneut speichern."
                else "Speichern fehlgeschlagen. Die letzte gespeicherte Fassung bleibt erhalten."
            )
        }
    }

    fun delete() { file.delete() }
}
