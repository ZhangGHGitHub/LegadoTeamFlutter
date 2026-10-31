package io.legado.flutter

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * [批9b-6 审查回修] WebServiceWakeLockSet 部分持锁/降级状态机单测。
 *
 * 覆盖两条 P2 缺陷的回归：
 * 1. Wi-Fi acquire 失败必须保持 wifi 句柄为 null（isHeld 只看 CPU），
 *    否则 CPU 锁对 Dart 不可见、停止时跳过 release 而残留；
 * 2. release 成功后清空句柄；CPU 失败保留（isHeld=true 供重试）；
 *    Wi-Fi 失败保留 CPU 锁，不产生「Wi-Fi 单锁」。
 *
 * 纯 JVM JUnit：用 FakeLock 注入，不触 Android 框架。
 */
class WebServiceWakeLockSetTest {

    private class FakeLock(
        var held: Boolean = false,
        var failAcquire: Boolean = false,
        var failRelease: Boolean = false,
    ) : WakeLockHandle {
        var acquireCount = 0
        var releaseCount = 0

        override val isHeld: Boolean get() = held

        override fun acquire() {
            acquireCount++
            if (failAcquire) throw IllegalStateException("acquire failed")
            held = true
        }

        override fun release() {
            releaseCount++
            if (failRelease) throw IllegalStateException("release failed")
            held = false
        }
    }

    private fun lockSet(cpu: FakeLock, wifi: FakeLock?) =
        WebServiceWakeLockSet(
            createCpuLock = { cpu },
            createWifiLock = { wifi },
        )

    @Test
    fun `wifi acquire failure degrades to cpu only and stays visible`() {
        val cpu = FakeLock()
        val wifi = FakeLock(failAcquire = true)
        val locks = lockSet(cpu, wifi)

        assertNull(locks.acquire())

        assertTrue(cpu.held)
        assertFalse(wifi.held)
        assertNull("Wi-Fi 获取失败不得缓存未持有的句柄", locks.wifiLockForTest())
        assertTrue("CPU-only 仍应视为持有（降级语义）", locks.isHeld())
    }

    @Test
    fun `release after degraded acquire still releases cpu`() {
        val cpu = FakeLock()
        val wifi = FakeLock(failAcquire = true)
        val locks = lockSet(cpu, wifi)
        locks.acquire()

        assertNull(locks.release())

        assertFalse(cpu.held)
        assertEquals(1, cpu.releaseCount)
        assertNull(locks.cpuLockForTest())
        assertFalse(locks.isHeld())
    }

    @Test
    fun `cpu release failure keeps held for retry`() {
        val cpu = FakeLock()
        val wifi = FakeLock()
        val locks = lockSet(cpu, wifi)
        locks.acquire()

        cpu.failRelease = true
        assertNotNull(locks.release())
        assertTrue("CPU 释放失败必须保留持有态供重试", cpu.held)
        assertTrue(locks.isHeld())

        cpu.failRelease = false
        assertNull(locks.release())
        assertFalse(cpu.held)
        assertFalse(locks.isHeld())
        assertNull(locks.cpuLockForTest())
    }

    @Test
    fun `wifi release failure keeps cpu held without single lock`() {
        val cpu = FakeLock()
        val wifi = FakeLock()
        val locks = lockSet(cpu, wifi)
        locks.acquire()

        wifi.failRelease = true
        assertNotNull(locks.release())
        assertTrue("Wi-Fi 释放失败时 CPU 锁必须保留", cpu.held)
        assertTrue(wifi.held)
        assertTrue(locks.isHeld())

        wifi.failRelease = false
        assertNull(locks.release())
        assertFalse(cpu.held)
        assertFalse(wifi.held)
        assertFalse(locks.isHeld())
        assertNull(locks.cpuLockForTest())
        assertNull(locks.wifiLockForTest())
    }

    @Test
    fun `acquire and release are idempotent`() {
        val cpu = FakeLock()
        val wifi = FakeLock()
        val locks = lockSet(cpu, wifi)

        locks.acquire()
        locks.acquire()
        assertEquals(1, cpu.acquireCount)
        assertEquals(1, wifi.acquireCount)

        locks.release()
        locks.release()
        assertEquals(1, cpu.releaseCount)
        assertEquals(1, wifi.releaseCount)
    }

    @Test
    fun `release without acquire succeeds and reports not held`() {
        val locks = lockSet(FakeLock(), FakeLock())

        assertNull(locks.release())
        assertFalse(locks.isHeld())
    }
}
