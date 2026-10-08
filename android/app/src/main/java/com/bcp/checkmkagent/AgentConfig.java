package com.bcp.checkmkagent;

import android.content.Context;
import android.content.SharedPreferences;
import android.os.Build;

import java.util.Locale;

public final class AgentConfig {
    public static final String PREFS = "cmkagent_prefs";
    private static final String KEY_HOSTNAME = "hostname";
    private static final String KEY_PORT = "port";
    private static final String KEY_DESIGN_CAPACITY = "design_capacity_mah";
    private static final String KEY_AUTOSTART = "autostart";
    private static final String KEY_ALLOWED_SERVER = "allowed_server";
    private static final String KEY_PUSH_ENABLED = "push_enabled";
    private static final String KEY_PUSH_URL = "push_url";
    private static final String KEY_PUSH_TOKEN = "push_token";
    private static final String KEY_PUSH_INTERVAL_SEC = "push_interval_sec";

    private AgentConfig() {}

    public static String getHostname(Context context) {
        SharedPreferences p = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        String fallback = sanitizeHostname("PDA-" + Build.MODEL);
        String value = p.getString(KEY_HOSTNAME, fallback);
        if (value == null || value.trim().isEmpty()) return fallback;
        return sanitizeHostname(value.trim());
    }

    public static int getPort(Context context) {
        SharedPreferences p = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        int port = p.getInt(KEY_PORT, 6556);
        return (port >= 1 && port <= 65535) ? port : 6556;
    }

    public static double getDesignCapacityMah(Context context) {
        SharedPreferences p = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        long bits = p.getLong(KEY_DESIGN_CAPACITY, Double.doubleToRawLongBits(0.0));
        double value = Double.longBitsToDouble(bits);
        return value > 0 ? value : 0.0;
    }

    public static boolean isAutoStart(Context context) {
        return context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .getBoolean(KEY_AUTOSTART, true);
    }

    /**
     * Empty means allow every source. A comma-separated list may be used.
     * For the production WMS network the recommended value is 192.168.55.112.
     */
    public static String getAllowedServer(Context context) {
        String value = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .getString(KEY_ALLOWED_SERVER, "");
        return value == null ? "" : value.trim();
    }

    public static boolean isClientAllowed(Context context, String remoteIp) {
        String allow = getAllowedServer(context);
        if (allow.isEmpty() || "*".equals(allow)) return true;
        if (remoteIp == null || remoteIp.trim().isEmpty()) return false;
        for (String item : allow.split(",")) {
            if (remoteIp.equals(item.trim())) return true;
        }
        return false;
    }

    public static boolean isPushEnabled(Context context) {
        return context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .getBoolean(KEY_PUSH_ENABLED, true);
    }

    public static String getPushUrl(Context context) {
        String value = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .getString(KEY_PUSH_URL, "");
        return value == null ? "" : value.trim();
    }

    public static String getPushToken(Context context) {
        String value = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .getString(KEY_PUSH_TOKEN, "");
        return value == null ? "" : value.trim();
    }

    public static int getPushIntervalSec(Context context) {
        int value = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .getInt(KEY_PUSH_INTERVAL_SEC, 300);
        if (value < 60) return 60;
        if (value > 86400) return 86400;
        return value;
    }

    public static boolean isPushConfigured(Context context) {
        return isPushEnabled(context) && !getPushUrl(context).isEmpty();
    }

    public static void save(Context context, String hostname, int port,
                            double designCapacityMah, boolean autoStart,
                            String allowedServer, boolean pushEnabled,
                            String pushUrl, String pushToken, int pushIntervalSec) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .edit()
                .putString(KEY_HOSTNAME, sanitizeHostname(hostname))
                .putInt(KEY_PORT, port)
                .putLong(KEY_DESIGN_CAPACITY,
                        Double.doubleToRawLongBits(Math.max(0.0, designCapacityMah)))
                .putBoolean(KEY_AUTOSTART, autoStart)
                .putString(KEY_ALLOWED_SERVER, allowedServer == null ? "" : allowedServer.trim())
                .putBoolean(KEY_PUSH_ENABLED, pushEnabled)
                .putString(KEY_PUSH_URL, pushUrl == null ? "" : pushUrl.trim())
                .putString(KEY_PUSH_TOKEN, pushToken == null ? "" : pushToken.trim())
                .putInt(KEY_PUSH_INTERVAL_SEC, Math.max(60, Math.min(86400, pushIntervalSec)))
                .apply();
    }

    public static String sanitizeHostname(String value) {
        if (value == null) return "ANDROID-PDA";
        String cleaned = value.trim().toUpperCase(Locale.US)
                .replaceAll("[^A-Z0-9._-]", "-")
                .replaceAll("-+", "-");
        if (cleaned.isEmpty()) return "ANDROID-PDA";
        return cleaned.length() > 63 ? cleaned.substring(0, 63) : cleaned;
    }
}
