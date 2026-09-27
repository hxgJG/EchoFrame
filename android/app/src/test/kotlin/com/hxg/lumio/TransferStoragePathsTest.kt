package com.hxg.lumio

import java.io.File
import java.nio.file.Files
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class TransferStoragePathsTest {
    @get:Rule val temporary = TemporaryFolder()

    @Test fun createsRootAndReusesExistingLockFile() {
        val base = temporary.newFolder("no_backup").canonicalFile
        val lock = TransferStoragePaths.lockFile(base)
        assertEquals(File(base, "lumio_transfer/.owner"), lock)
        lock.writeText("existing")
        assertEquals(lock, TransferStoragePaths.lockFile(base))
        assertEquals("existing", lock.readText())
    }

    @Test fun acceptsSystemPrivateDirectoryAlias() {
        val base = temporary.newFolder("real_no_backup").canonicalFile
        val alias = File(temporary.root, "system_alias")
        Files.createSymbolicLink(alias.toPath(), base.toPath())
        val lock = TransferStoragePaths.lockFile(alias)
        assertEquals(File(base, "lumio_transfer/.owner"), lock)
        assertEquals(TransferStoragePaths.root(base), TransferStoragePaths.root(alias))
    }

    @Test fun rejectsRedirectedTransferRoot() {
        val base = temporary.newFolder("no_backup")
        val outside = temporary.newFolder("outside")
        Files.createSymbolicLink(File(base, "lumio_transfer").toPath(), outside.toPath())
        assertThrows(IllegalArgumentException::class.java) { TransferStoragePaths.lockFile(base) }
        assertFalse(File(outside, ".owner").exists())
    }

    @Test fun rejectsFileInPlaceOfDirectory() {
        val base = temporary.newFolder("no_backup")
        File(base, "lumio_transfer").writeText("keep")
        assertThrows(java.io.IOException::class.java) { TransferStoragePaths.root(base) }
        assertEquals("keep", File(base, "lumio_transfer").readText())
    }

    @Test fun rejectsRedirectedLockFile() {
        val base = temporary.newFolder("no_backup")
        val outside = temporary.newFile("outside")
        outside.writeText("keep")
        val root = TransferStoragePaths.root(base)
        Files.createSymbolicLink(File(root, ".owner").toPath(), outside.toPath())
        assertThrows(IllegalArgumentException::class.java) { TransferStoragePaths.lockFile(base) }
        assertEquals("keep", outside.readText())
    }

    @Test fun rejectsDanglingLockLink() {
        val base = temporary.newFolder("no_backup")
        val outside = File(temporary.root, "missing")
        val root = TransferStoragePaths.root(base)
        Files.createSymbolicLink(File(root, ".owner").toPath(), outside.toPath())
        assertThrows(IllegalArgumentException::class.java) { TransferStoragePaths.lockFile(base) }
        assertFalse(outside.exists())
    }

    @Test fun rejectsDirectoryInPlaceOfLock() {
        val base = temporary.newFolder("no_backup")
        File(TransferStoragePaths.root(base), ".owner").mkdir()
        assertThrows(IllegalArgumentException::class.java) { TransferStoragePaths.lockFile(base) }
    }
}
