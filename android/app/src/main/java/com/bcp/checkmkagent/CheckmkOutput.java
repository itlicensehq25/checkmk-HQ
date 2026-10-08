package com.bcp.checkmkagent;

import android.content.Context;
import android.content.SharedPreferences;

import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.Locale;
import java.util.concurrent.TimeUnit;

public final class CheckmkOutput {
    public static final String VERSION = "1.3.4";
    private static final String PREFS_CACHE = "cmkagent_metrics_cache";

    private static final long INTERVAL_TEMP_SEC = 1800L;
    private static final long INTERVAL_CURRENT_SEC = 3600L;
    private static final long INTERVAL_TRANSPORT_SEC = 10800L;
    private static final long INTERVAL_VOLTAGE_SEC = 86400L;
    private static final long INTERVAL_STORAGE_SEC = 86400L;

    private CheckmkOutput() {}

    private static final class CachedEntry {
        final String line;
        final long epochSec;

        CachedEntry(String line, long epochSec) {
            this.line = line;
            this.epochSec = epochSec;
        }
    }

    private interface LineGenerator {
        String generate();
    }

    private static CachedEntry getOrUpdateCache(Context context, String key, long intervalSec, LineGenerator generator) {
        SharedPreferences p = context.getSharedPreferences(PREFS_CACHE, Context.MODE_PRIVATE);
        long nowSec = System.currentTimeMillis() / 1000L;
        long lastSec = p.getLong(key + "_ts", 0L);
        String cachedLine = p.getString(key + "_line", null);

        if (cachedLine == null || (nowSec - lastSec) >= intervalSec || lastSec > nowSec) {
            String newLine = generator.generate();
            p.edit()
                    .putString(key + "_line", newLine)
                    .putLong(key + "_ts", nowSec)
                    .apply();
            return new CachedEntry(newLine, nowSec);
        }
        return new CachedEntry(cachedLine, lastSec);
    }

    public static String build(Context context) {
        DeviceMetrics.BatteryInfo battery = DeviceMetrics.readBattery(context);
        DeviceMetrics.UsageInfo ram = DeviceMetrics.readRam(context);
        DeviceMetrics.WifiStatus wifi = DeviceMetrics.readWifi(context);
        DeviceMetrics.DeviceInfo device = DeviceMetrics.readDeviceInfo();
        AgentStats.Snapshot stats = AgentStats.read(context);

        StringBuilder sb = new StringBuilder();
        sb.append("<<<check_mk>>>\n");
        sb.append("Version: ").append(VERSION).append("\n");
        sb.append("AgentOS: android\n");
        sb.append("Hostname: ").append(AgentConfig.getHostname(context)).append("\n\n");

        sb.append("<<<local:sep(0)>>>\n");
        sb.append(buildAgentStatusLine(context, stats)).append('\n');
        sb.append(buildBatteryLevelLine(battery)).append('\n');
        sb.append(buildBatteryHealthLine(battery)).append('\n');
        sb.append(buildRamLine(ram)).append('\n');
        sb.append(buildWifiLine(wifi)).append('\n');
        sb.append(buildAndroidInfoLine(device)).append('\n');

        CachedEntry tempEntry = getOrUpdateCache(context, "bat_temp", INTERVAL_TEMP_SEC,
                () -> buildBatteryTemperatureLine(battery));
        sb.append("<<<local:cached(").append(tempEntry.epochSec).append(",")
                .append(INTERVAL_TEMP_SEC).append("):sep(0)>>>\n");
        sb.append(tempEntry.line).append('\n');

        CachedEntry currentEntry = getOrUpdateCache(context, "bat_current", INTERVAL_CURRENT_SEC,
                () -> buildBatteryCurrentLine(battery));
        sb.append("<<<local:cached(").append(currentEntry.epochSec).append(",")
                .append(INTERVAL_CURRENT_SEC).append("):sep(0)>>>\n");
        sb.append(currentEntry.line).append('\n');

        CachedEntry transportEntry = getOrUpdateCache(context, "transport", INTERVAL_TRANSPORT_SEC,
                () -> buildTransportStatusLine(context, stats));
        sb.append("<<<local:cached(").append(transportEntry.epochSec).append(",")
                .append(INTERVAL_TRANSPORT_SEC).append("):sep(0)>>>\n");
        sb.append(transportEntry.line).append('\n');

        CachedEntry voltageEntry = getOrUpdateCache(context, "bat_voltage", INTERVAL_VOLTAGE_SEC,
                () -> buildBatteryVoltageLine(battery));
        sb.append("<<<local:cached(").append(voltageEntry.epochSec).append(",")
                .append(INTERVAL_VOLTAGE_SEC).append("):sep(0)>>>\n");
        sb.append(voltageEntry.line).append('\n');

        CachedEntry storageEntry = getOrUpdateCache(context, "storage", INTERVAL_STORAGE_SEC,
                () -> buildStorageLine(DeviceMetrics.readStorage()));
        sb.append("<<<local:cached(").append(storageEntry.epochSec).append(",")
                .append(INTERVAL_STORAGE_SEC).append("):sep(0)>>>\n");
        sb.append(storageEntry.line).append('\n');

        return sb.toString();
    }

    private static String buildAgentStatusLine(Context context, AgentStats.Snapshot s) {
        long now = System.currentTimeMillis();
        String lastPull = s.lastPullMs > 0 ? formatDate(s.lastPullMs) : "N/A";
        String age = s.lastPullMs > 0 ? formatDuration(Math.max(0, now - s.lastPullMs)) + " ago" : "N/A";
        String allow = AgentConfig.getAllowedServer(context);
        if (allow.isEmpty()) allow = "Any source";
        return "0 \"Agent_Status\" connections=" + s.accepted + "|rejected=" + s.rejected
                + " Status : OK"
                + " | Version : " + VERSION
                + " | Port : " + AgentConfig.getPort(context)
                + " | Last Pull : " + lastPull + " (" + age + ")"
                + " | Last Client : " + s.lastClient
                + " | Allowed Server : " + allow
                + " | Collection : Hybrid (pull primary + push backup)";
    }

    private static String buildTransportStatusLine(Context context, AgentStats.Snapshot s) {
        String endpoint = AgentConfig.getPushUrl(context);
        boolean configured = AgentConfig.isPushConfigured(context);
        int state = 0;
        String status;
        if (!configured) {
            status = "Push backup not configured";
        } else if (s.lastPushMs <= 0) {
            state = 1;
            status = "Push backup configured, waiting for first delivery";
        } else if (s.lastPushOk) {
            status = "Push backup healthy";
        } else {
            state = 1;
            status = "Push backup last delivery failed";
        }

        String lastPush = s.lastPushMs > 0 ? formatDate(s.lastPushMs) : "N/A";
        String age = s.lastPushMs > 0
                ? formatDuration(Math.max(0, System.currentTimeMillis() - s.lastPushMs)) + " ago"
                : "N/A";
        String safeEndpoint = endpoint.isEmpty() ? "Not configured" : endpoint;

        return state + " \"Transport_Status\" push_success=" + s.pushSuccesses
                + "|push_failure=" + s.pushFailures
                + " Status : " + stateName(state)
                + " | Primary : PULL TCP/" + AgentConfig.getPort(context)
                + " | Backup : PUSH HTTP(S)"
                + " | Receiver : " + safeEndpoint
                + " | Push Interval : " + AgentConfig.getPushIntervalSec(context) + " sec"
                + " | Last Push : " + lastPush + " (" + age + ")"
                + " | Last Push Result : " + status
                + " | HTTP Code : " + (s.lastPushCode > 0 ? s.lastPushCode : "N/A")
                + " | Detail : " + s.lastPushMessage;
    }

    private static String buildBatteryLevelLine(DeviceMetrics.BatteryInfo b) {
        int state = 0;
        if (b.level >= 0) {
            if (b.level < 15) state = 2;
            else if (b.level < 30) state = 1;
        }
        String level = b.level >= 0 ? b.level + "%" : "N/A";
        String metric = b.level >= 0 ? "battery_level=" + b.level : "-";
        return state + " \"Battery_Level\" " + metric
                + " Status : " + stateName(state)
                + " | Battery Level : " + level
                + " | Charging State : " + b.status;
    }

    private static String buildBatteryHealthLine(DeviceMetrics.BatteryInfo b) {
        if (Double.isNaN(b.healthPercent)) {
            return "0 \"Health_Battery\" - Status : OK | Health : N/A (Calculating real metrics)";
        }

        int state = 0;
        if (b.healthPercent < 65.0 || (b.cycleCount >= 800)) {
            state = 2;
        } else if (b.healthPercent < 80.0 || (b.cycleCount >= 500)) {
            state = 1;
        }

        String fullStr = Double.isNaN(b.fullCapacityMah) ? "N/A" : Math.round(b.fullCapacityMah) + " mAh";
        String designStr = Double.isNaN(b.designCapacityMah) ? "N/A" : Math.round(b.designCapacityMah) + " mAh";
        String chargeStr = Double.isNaN(b.chargeCounterMah) ? "N/A" : Math.round(b.chargeCounterMah) + " mAh";
        String fullVoltStr = Double.isNaN(b.fullChargeVoltageV) ? "" : String.format(Locale.US, " | Full Voltage : %.2f V", b.fullChargeVoltageV);
        String cycleStr = (b.cycleCount >= 0) ? (" | Cycles : " + b.cycleCount) : " | Cycles : N/A";

        String metric = "battery_health=" + String.format(Locale.US, "%.1f", b.healthPercent) + ";80;65;0;100";
        if (b.cycleCount >= 0) {
            metric += "|battery_cycles=" + b.cycleCount + ";500;800;0";
        }

        return state + " \"Health_Battery\" " + metric
                + " Status : " + stateName(state)
                + " | Real Health : " + String.format(Locale.US, "%.1f%%", b.healthPercent)
                + cycleStr
                + " | Full Capacity : " + fullStr
                + " | Design Spec : " + designStr
                + fullVoltStr
                + " | Current Charge : " + chargeStr
                + " | Calculation : " + b.fullCapacitySource;
    }

    private static String buildBatteryTemperatureLine(DeviceMetrics.BatteryInfo b) {
        int state = 0;
        if (!Double.isNaN(b.temperatureC)) {
            if (b.temperatureC >= 48.0) state = 2;
            else if (b.temperatureC >= 42.0) state = 1;
        }
        String value = !Double.isNaN(b.temperatureC)
                ? String.format(Locale.US, "%.1f C", b.temperatureC) : "N/A";
        String metric = !Double.isNaN(b.temperatureC)
                ? String.format(Locale.US, "battery_temp=%.1f;42;48", b.temperatureC) : "-";
        return state + " \"Battery_Temperature\" " + metric
                + " Status : " + stateName(state) + " | Temperature : " + value;
    }

    private static String buildBatteryVoltageLine(DeviceMetrics.BatteryInfo b) {
        String value = !Double.isNaN(b.voltageV)
                ? String.format(Locale.US, "%.2f V", b.voltageV) : "N/A";
        String metric = !Double.isNaN(b.voltageV)
                ? String.format(Locale.US, "battery_voltage=%.3f", b.voltageV) : "-";
        return "0 \"Battery_Voltage\" " + metric
                + " Status : OK | Voltage : " + value;
    }

    private static String buildBatteryCurrentLine(DeviceMetrics.BatteryInfo b) {
        String now = !Double.isNaN(b.currentNowMa)
                ? String.format(Locale.US, "%.0f mA", b.currentNowMa) : "N/A";
        String avg = !Double.isNaN(b.currentAverageMa)
                ? String.format(Locale.US, "%.0f mA", b.currentAverageMa) : "N/A";
        String metric = !Double.isNaN(b.currentNowMa)
                ? String.format(Locale.US, "battery_current=%.0f", b.currentNowMa) : "-";
        return "0 \"Battery_Current\" " + metric
                + " Status : OK | Current Now : " + now + " | Current Average : " + avg;
    }

    private static String buildRamLine(DeviceMetrics.UsageInfo r) {
        int state = thresholdHigh(r.usedPercent, 85.0, 95.0);
        return state + " \"RAM_Usage\" ram_used=" + Math.round(r.usedPercent) + ";85;95"
                + " Status : " + stateName(state)
                + " | Used : " + Math.round(r.usedPercent) + "% (" + DeviceMetrics.fmt2(r.usedGb) + " GB)"
                + " | Free : " + DeviceMetrics.fmt2(r.freeGb) + " GB"
                + " | Total : " + DeviceMetrics.fmt2(r.totalGb) + " GB";
    }

    private static String buildStorageLine(DeviceMetrics.UsageInfo s) {
        int state = thresholdHigh(s.usedPercent, 85.0, 95.0);
        return state + " \"Storage_Usage\" storage_used=" + Math.round(s.usedPercent) + ";85;95"
                + " Status : " + stateName(state)
                + " | Used : " + Math.round(s.usedPercent) + "% (" + DeviceMetrics.fmt2(s.usedGb) + " GB)"
                + " | Free : " + DeviceMetrics.fmt2(s.freeGb) + " GB"
                + " | Total : " + DeviceMetrics.fmt2(s.totalGb) + " GB";
    }

    private static String buildWifiLine(DeviceMetrics.WifiStatus w) {
        if (!w.connected) {
            return "1 \"WiFi_Status\" - Status : Not Connected | WiFi not connected"
                    + " | IP : " + w.ip;
        }
        int state = 0;
        if (w.rssi != Integer.MIN_VALUE) {
            if (w.rssi <= -75) state = 2;
            else if (w.rssi <= -68) state = 1;
        }
        String metric = w.rssi != Integer.MIN_VALUE ? "wifi_rssi=" + w.rssi : "-";
        String rssi = w.rssi != Integer.MIN_VALUE ? w.rssi + " dBm" : "N/A";
        String speed = w.linkSpeedMbps >= 0 ? w.linkSpeedMbps + " Mbps" : "N/A";
        String freq = w.frequencyMhz >= 0 ? w.frequencyMhz + " MHz" : "N/A";
        return state + " \"WiFi_Status\" " + metric
                + " Status : " + stateName(state)
                + " | SSID : " + w.ssid
                + " | Signal : " + rssi
                + " | Link Speed : " + speed
                + " | Frequency : " + freq
                + " | IP : " + w.ip
                + " | Detection : " + w.detectionSource;
    }

    private static String buildAndroidInfoLine(DeviceMetrics.DeviceInfo d) {
        return "0 \"Android_Info\" - Status : OK"
                + " | Manufacturer : " + d.manufacturer
                + " | Model : " + d.model
                + " | Profile : " + d.profile
                + " | Android : " + d.androidVersion
                + " | SDK : " + d.sdk
                + " | Uptime : " + formatDuration(d.uptimeMs);
    }

    private static int thresholdHigh(double value, double warn, double crit) {
        if (value >= crit) return 2;
        if (value >= warn) return 1;
        return 0;
    }

    private static String stateName(int state) {
        switch (state) {
            case 1: return "WARNING";
            case 2: return "CRITICAL";
            case 3: return "UNKNOWN";
            default: return "OK";
        }
    }

    public static String formatDuration(long ms) {
        long totalMinutes = Math.max(0L, TimeUnit.MILLISECONDS.toMinutes(ms));
        long days = totalMinutes / (24 * 60);
        long hours = (totalMinutes / 60) % 24;
        long minutes = totalMinutes % 60;
        if (days > 0) return days + "d " + hours + "h " + minutes + "m";
        if (hours > 0) return hours + "h " + minutes + "m";
        return minutes + "m";
    }

    private static String formatDate(long millis) {
        return new SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.getDefault())
                .format(new Date(millis));
    }
}
