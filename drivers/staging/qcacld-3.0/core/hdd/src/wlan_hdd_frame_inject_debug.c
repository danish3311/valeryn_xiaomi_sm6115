/*
 * Copyright (c) 2024 The Linux Foundation. All rights reserved.
 *
 * Permission to use, copy, modify, and/or distribute this software for
 * any purpose with or without fee is hereby granted, provided that the
 * above copyright notice and this permission notice appear in all
 * copies.
 *
 * THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL
 * WARRANTIES WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE
 * AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL
 * DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR
 * PROFITS, WHETHER IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER
 * TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION WITH THE USE OR
 * PERFORMANCE OF THIS SOFTWARE.
 */

/**
 * DOC: wlan_hdd_frame_inject_debug.c
 *
 * WLAN Host Device Driver Frame Injection Debug and Diagnostic Interfaces
 */

#include "wlan_hdd_includes.h"
#include "wlan_hdd_frame_inject.h"
#include <linux/sysfs.h>
#include <linux/kobject.h>
#include <qdf_mem.h>
#include <qdf_trace.h>
#include <qdf_time.h>

#ifdef FEATURE_FRAME_INJECTION_SUPPORT

/* Debug logging levels */
#define HDD_INJECT_DEBUG_LEVEL_NONE    0
#define HDD_INJECT_DEBUG_LEVEL_ERROR   1
#define HDD_INJECT_DEBUG_LEVEL_WARN    2
#define HDD_INJECT_DEBUG_LEVEL_INFO    3
#define HDD_INJECT_DEBUG_LEVEL_DEBUG   4
#define HDD_INJECT_DEBUG_LEVEL_VERBOSE 5

/* Global debug level */
static uint8_t g_injection_debug_level = HDD_INJECT_DEBUG_LEVEL_INFO;

static void hdd_injection_sync_global_enable_to_adapters(bool enable);

/* Global configuration parameters */
static bool g_injection_global_enable = true;
static uint32_t g_injection_max_frame_rate = HDD_FRAME_INJECT_DEFAULT_RATE_LIMIT;
static uint32_t g_injection_max_frame_size = HDD_FRAME_INJECT_MAX_SIZE;
static uint32_t g_injection_max_queue_size = HDD_FRAME_INJECT_MAX_QUEUE_SIZE;
static uint32_t g_injection_monitor_off_idle_sec =
	HDD_FRAME_INJECT_MONITOR_OFF_IDLE_SEC;
/* qdf log timestamp (usecs) of last injection activity; 0 = never */
static uint64_t g_injection_last_activity_us;
static uint32_t g_injection_rate_window_ms = HDD_FRAME_INJECT_RATE_WINDOW_MS;
static bool g_injection_require_monitor_mode = false;

/* Sysfs kobject */
static struct kobject *g_injection_sysfs_kobj = NULL;


/**
 * hdd_injection_sysfs_debug_level_show() - Show debug level via sysfs
 * @kobj: Kobject pointer
 * @attr: Attribute pointer
 * @buf: Buffer to write to
 *
 * Return: Number of bytes written
 */
static ssize_t hdd_injection_sysfs_debug_level_show(struct kobject *kobj,
						     struct kobj_attribute *attr,
						     char *buf)
{
	return scnprintf(buf, PAGE_SIZE, "%u\n", g_injection_debug_level);
}

/**
 * hdd_injection_sysfs_debug_level_store() - Set debug level via sysfs
 * @kobj: Kobject pointer
 * @attr: Attribute pointer
 * @buf: Buffer to read from
 * @count: Number of bytes to read
 *
 * Return: Number of bytes read, or error code
 */
static ssize_t hdd_injection_sysfs_debug_level_store(struct kobject *kobj,
						      struct kobj_attribute *attr,
						      const char *buf,
						      size_t count)
{
	uint8_t debug_level;
	int ret;

	ret = kstrtou8(buf, 10, &debug_level);
	if (ret) {
		return ret;
	}

	if (debug_level > HDD_INJECT_DEBUG_LEVEL_VERBOSE) {
		return -EINVAL;
	}

	g_injection_debug_level = debug_level;
	return count;
}

/**
 * hdd_injection_sysfs_global_enable_show() - Show global enable status via sysfs
 * @kobj: Kobject pointer
 * @attr: Attribute pointer
 * @buf: Buffer to write to
 *
 * Return: Number of bytes written
 */
static ssize_t hdd_injection_sysfs_global_enable_show(struct kobject *kobj,
						       struct kobj_attribute *attr,
						       char *buf)
{
	return scnprintf(buf, PAGE_SIZE, "%u\n", g_injection_global_enable ? 1 : 0);
}

/**
 * hdd_injection_sysfs_global_enable_store() - Set global enable status via sysfs
 * @kobj: Kobject pointer
 * @attr: Attribute pointer
 * @buf: Buffer to read from
 * @count: Number of bytes to read
 *
 * Return: Number of bytes read, or error code
 */
static ssize_t hdd_injection_sysfs_global_enable_store(struct kobject *kobj,
							struct kobj_attribute *attr,
							const char *buf,
							size_t count)
{
	bool enable;
	int ret;

	ret = kstrtobool(buf, &enable);
	if (ret) {
		return ret;
	}

	g_injection_global_enable = enable;
	/*
	 * Propagate to already-initialized adapters. Permission checks used to
	 * read a one-time snapshot from hdd_init_injection_security_ctx();
	 * without this walk, sysfs global_enable=1 left stale false in place.
	 */
	hdd_injection_sync_global_enable_to_adapters(enable);
	pr_info("Frame injection global enable set to: %s\n",
		enable ? "true" : "false");

	return count;
}

/**
 * Additional sysfs configuration functions
 */
static ssize_t hdd_injection_sysfs_max_frame_rate_show(struct kobject *kobj,
							struct kobj_attribute *attr,
							char *buf)
{
	return scnprintf(buf, PAGE_SIZE, "%u\n", g_injection_max_frame_rate);
}

static ssize_t hdd_injection_sysfs_max_frame_rate_store(struct kobject *kobj,
							 struct kobj_attribute *attr,
							 const char *buf,
							 size_t count)
{
	uint32_t rate;
	int ret;

	ret = kstrtou32(buf, 10, &rate);
	if (ret) {
		return ret;
	}

	if (rate > 10000) { /* Reasonable upper limit */
		return -EINVAL;
	}

	g_injection_max_frame_rate = rate;
	return count;
}

static ssize_t hdd_injection_sysfs_max_frame_size_show(struct kobject *kobj,
							struct kobj_attribute *attr,
							char *buf)
{
	return scnprintf(buf, PAGE_SIZE, "%u\n", g_injection_max_frame_size);
}

static ssize_t hdd_injection_sysfs_max_frame_size_store(struct kobject *kobj,
							 struct kobj_attribute *attr,
							 const char *buf,
							 size_t count)
{
	uint32_t size;
	int ret;

	ret = kstrtou32(buf, 10, &size);
	if (ret) {
		return ret;
	}

	if (size < 64 || size > 4096) { /* Reasonable bounds */
		return -EINVAL;
	}

	g_injection_max_frame_size = size;
	return count;
}

static ssize_t hdd_injection_sysfs_max_queue_size_show(struct kobject *kobj,
							struct kobj_attribute *attr,
							char *buf)
{
	return scnprintf(buf, PAGE_SIZE, "%u\n", g_injection_max_queue_size);
}

static ssize_t hdd_injection_sysfs_max_queue_size_store(struct kobject *kobj,
							 struct kobj_attribute *attr,
							 const char *buf,
							 size_t count)
{
	uint32_t size;
	int ret;

	ret = kstrtou32(buf, 10, &size);
	if (ret) {
		return ret;
	}

	if (size < 1 || size > 1024) { /* Reasonable bounds */
		return -EINVAL;
	}

	g_injection_max_queue_size = size;
	return count;
}

static ssize_t hdd_injection_sysfs_rate_window_ms_show(struct kobject *kobj,
							struct kobj_attribute *attr,
							char *buf)
{
	return scnprintf(buf, PAGE_SIZE, "%u\n", g_injection_rate_window_ms);
}

static ssize_t hdd_injection_sysfs_rate_window_ms_store(struct kobject *kobj,
							 struct kobj_attribute *attr,
							 const char *buf,
							 size_t count)
{
	uint32_t window;
	int ret;

	ret = kstrtou32(buf, 10, &window);
	if (ret) {
		return ret;
	}

	if (window < 100 || window > 60000) { /* 100ms to 60s */
		return -EINVAL;
	}

	g_injection_rate_window_ms = window;
	return count;
}

static ssize_t hdd_injection_sysfs_require_monitor_mode_show(struct kobject *kobj,
							     struct kobj_attribute *attr,
							     char *buf)
{
	return scnprintf(buf, PAGE_SIZE, "%u\n", g_injection_require_monitor_mode ? 1 : 0);
}

static ssize_t hdd_injection_sysfs_require_monitor_mode_store(struct kobject *kobj,
							      struct kobj_attribute *attr,
							      const char *buf,
							      size_t count)
{
	bool require;
	int ret;

	ret = kstrtobool(buf, &require);
	if (ret) {
		return ret;
	}

	g_injection_require_monitor_mode = require;
	return count;
}

static ssize_t hdd_injection_sysfs_monitor_off_idle_sec_show(struct kobject *kobj,
							    struct kobj_attribute *attr,
							    char *buf)
{
	return scnprintf(buf, PAGE_SIZE, "%u\n", g_injection_monitor_off_idle_sec);
}

static ssize_t hdd_injection_sysfs_monitor_off_idle_sec_store(struct kobject *kobj,
							     struct kobj_attribute *attr,
							     const char *buf,
							     size_t count)
{
	uint32_t sec;
	int ret;

	ret = kstrtou32(buf, 10, &sec);
	if (ret)
		return ret;

	/* 0 disables the idle escape (block OFF indefinitely while monitor) */
	g_injection_monitor_off_idle_sec = sec;
	pr_info("Frame injection monitor_off_idle_sec set to %u\n", sec);
	return count;
}

/* Sysfs attributes */
static struct kobj_attribute hdd_injection_debug_level_attr =
	__ATTR(debug_level, 0644, hdd_injection_sysfs_debug_level_show,
	       hdd_injection_sysfs_debug_level_store);

static struct kobj_attribute hdd_injection_global_enable_attr =
	__ATTR(global_enable, 0644, hdd_injection_sysfs_global_enable_show,
	       hdd_injection_sysfs_global_enable_store);

static struct kobj_attribute hdd_injection_max_frame_rate_attr =
	__ATTR(max_frame_rate, 0644, hdd_injection_sysfs_max_frame_rate_show,
	       hdd_injection_sysfs_max_frame_rate_store);

static struct kobj_attribute hdd_injection_max_frame_size_attr =
	__ATTR(max_frame_size, 0644, hdd_injection_sysfs_max_frame_size_show,
	       hdd_injection_sysfs_max_frame_size_store);

static struct kobj_attribute hdd_injection_max_queue_size_attr =
	__ATTR(max_queue_size, 0644, hdd_injection_sysfs_max_queue_size_show,
	       hdd_injection_sysfs_max_queue_size_store);

static struct kobj_attribute hdd_injection_rate_window_ms_attr =
	__ATTR(rate_window_ms, 0644, hdd_injection_sysfs_rate_window_ms_show,
	       hdd_injection_sysfs_rate_window_ms_store);

static struct kobj_attribute hdd_injection_require_monitor_mode_attr =
	__ATTR(require_monitor_mode, 0644, hdd_injection_sysfs_require_monitor_mode_show,
	       hdd_injection_sysfs_require_monitor_mode_store);

static struct kobj_attribute hdd_injection_monitor_off_idle_sec_attr =
	__ATTR(monitor_off_idle_sec, 0644,
	       hdd_injection_sysfs_monitor_off_idle_sec_show,
	       hdd_injection_sysfs_monitor_off_idle_sec_store);

static struct attribute *hdd_injection_sysfs_attrs[] = {
	&hdd_injection_debug_level_attr.attr,
	&hdd_injection_global_enable_attr.attr,
	&hdd_injection_max_frame_rate_attr.attr,
	&hdd_injection_max_frame_size_attr.attr,
	&hdd_injection_max_queue_size_attr.attr,
	&hdd_injection_rate_window_ms_attr.attr,
	&hdd_injection_require_monitor_mode_attr.attr,
	&hdd_injection_monitor_off_idle_sec_attr.attr,
	NULL,
};

static struct attribute_group hdd_injection_sysfs_attr_group = {
	.attrs = hdd_injection_sysfs_attrs,
};

/**
 * hdd_injection_create_debugfs_entries() - stub (debugfs unused)
 * @adapter: HDD adapter
 *
 * Injection controls live under /sys/kernel/frame_injection (sysfs).
 * Return: QDF_STATUS_SUCCESS
 */
QDF_STATUS hdd_injection_create_debugfs_entries(struct hdd_adapter *adapter)
{
	return QDF_STATUS_SUCCESS;
}

/**
 * hdd_injection_remove_debugfs_entries() - stub (debugfs unused)
 * @adapter: HDD adapter
 *
 * Return: QDF_STATUS_SUCCESS
 */
QDF_STATUS hdd_injection_remove_debugfs_entries(struct hdd_adapter *adapter)
{
	return QDF_STATUS_SUCCESS;
}

/**
 * hdd_injection_init_debug_interfaces() - Initialize sysfs for frame injection
 *
 * Return: QDF_STATUS_SUCCESS on success, error code on failure
 */
QDF_STATUS hdd_injection_init_debug_interfaces(void)
{
	int ret;

	/* Sysfs only — debugfs path removed (always failed / unused) */
	g_injection_sysfs_kobj = kobject_create_and_add("frame_injection",
							 kernel_kobj);
	if (!g_injection_sysfs_kobj) {
		hdd_warn("Failed to create frame injection sysfs kobject");
	} else {
		ret = sysfs_create_group(g_injection_sysfs_kobj,
					 &hdd_injection_sysfs_attr_group);
		if (ret) {
			hdd_warn("Failed to create sysfs attribute group: %d", ret);
			kobject_put(g_injection_sysfs_kobj);
			g_injection_sysfs_kobj = NULL;
		}
	}

	hdd_info("Frame injection sysfs interfaces initialized");
	return QDF_STATUS_SUCCESS;
}

/**
 * hdd_injection_deinit_debug_interfaces() - Deinitialize sysfs interfaces
 *
 * Return: QDF_STATUS_SUCCESS on success, error code on failure
 */
QDF_STATUS hdd_injection_deinit_debug_interfaces(void)
{
	if (g_injection_sysfs_kobj) {
		sysfs_remove_group(g_injection_sysfs_kobj,
				   &hdd_injection_sysfs_attr_group);
		kobject_put(g_injection_sysfs_kobj);
		g_injection_sysfs_kobj = NULL;
	}

	hdd_info("Frame injection sysfs interfaces deinitialized");
	return QDF_STATUS_SUCCESS;
}

/**
 * hdd_injection_log_with_level() - Log message with configurable level
 * @level: Log level
 * @fmt: Format string
 * @...: Variable arguments
 *
 * This function provides configurable debug logging for frame injection.
 */
void hdd_injection_log_with_level(uint8_t level, const char *fmt, ...)
{
	va_list args;
	char log_buf[256];

	if (level > g_injection_debug_level) {
		return;
	}

	va_start(args, fmt);
	vsnprintf(log_buf, sizeof(log_buf), fmt, args);
	va_end(args);

	switch (level) {
	case HDD_INJECT_DEBUG_LEVEL_ERROR:
		hdd_err("INJECT: %s", log_buf);
		break;
	case HDD_INJECT_DEBUG_LEVEL_WARN:
		hdd_warn("INJECT: %s", log_buf);
		break;
	case HDD_INJECT_DEBUG_LEVEL_INFO:
		hdd_info("INJECT: %s", log_buf);
		break;
	case HDD_INJECT_DEBUG_LEVEL_DEBUG:
		hdd_debug("INJECT: %s", log_buf);
		break;
	case HDD_INJECT_DEBUG_LEVEL_VERBOSE:
		QDF_TRACE(QDF_MODULE_ID_HDD, QDF_TRACE_LEVEL_DEBUG,
			  "INJECT: %s", log_buf);
		break;
	default:
		break;
	}
}

/**
 * hdd_injection_get_global_config() - Get global injection configuration
 * @config: Pointer to configuration structure to fill
 *
 * This function retrieves the current global configuration parameters
 * that can be modified via sysfs interface.
 *
 * Return: QDF_STATUS_SUCCESS on success, error code on failure
 */
QDF_STATUS hdd_injection_get_global_config(struct injection_config *config)
{
	if (!config) {
		return QDF_STATUS_E_INVAL;
	}

	config->injection_enabled = g_injection_global_enable;
	config->max_frame_rate = g_injection_max_frame_rate;
	config->max_frame_size = g_injection_max_frame_size;
	config->max_queue_size = g_injection_max_queue_size;
	config->rate_window_ms = g_injection_rate_window_ms;
	config->require_monitor_mode = g_injection_require_monitor_mode;
	config->log_level = g_injection_debug_level;

	return QDF_STATUS_SUCCESS;
}

/**
 * hdd_injection_is_globally_enabled() - Check if injection is globally enabled
 *
 * This function checks the global enable flag that can be controlled
 * via sysfs interface.
 *
 * Return: true if globally enabled, false otherwise
 */
bool hdd_injection_is_globally_enabled(void)
{
	return g_injection_global_enable;
}

uint8_t hdd_injection_get_debug_level(void)
{
	return g_injection_debug_level;
}

void hdd_injection_note_activity(void)
{
	g_injection_last_activity_us = qdf_get_log_timestamp_usecs();
}

uint32_t hdd_injection_get_monitor_off_idle_sec(void)
{
	return g_injection_monitor_off_idle_sec;
}

bool hdd_injection_monitor_off_idle_expired(void)
{
	uint64_t now_us, idle_us;

	/* 0 = idle escape disabled: never expire */
	if (!g_injection_monitor_off_idle_sec)
		return false;

	/* No activity recorded yet — treat as idle so OFF is not stuck forever */
	if (!g_injection_last_activity_us)
		return true;

	now_us = qdf_get_log_timestamp_usecs();
	if (now_us < g_injection_last_activity_us)
		return true;

	idle_us = now_us - g_injection_last_activity_us;
	return idle_us >= ((uint64_t)g_injection_monitor_off_idle_sec * 1000000ULL);
}

static QDF_STATUS hdd_injection_sync_enable_cb(struct hdd_adapter *adapter,
					       void *context)
{
	bool enable = *((bool *)context);

	if (adapter && adapter->injection_ctx)
		adapter->injection_ctx->security_ctx.config.injection_enabled =
			enable;

	return QDF_STATUS_SUCCESS;
}

/**
 * hdd_injection_sync_global_enable_to_adapters() - Push global_enable live
 * @enable: New global enable value
 *
 * security_ctx->config.injection_enabled is snapshotted at adapter init.
 * Sysfs writes must update already-open adapters or permission checks keep
 * using a stale false until rmmod/modprobe.
 */
static void hdd_injection_sync_global_enable_to_adapters(bool enable)
{
	hdd_adapter_iterate(hdd_injection_sync_enable_cb, &enable);
}

#endif /* FEATURE_FRAME_INJECTION_SUPPORT */