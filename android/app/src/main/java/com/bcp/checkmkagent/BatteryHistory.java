package com.bcp.checkmkagent;

import android.content.Context;
import android.content.SharedPreferences;

import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Locale;

public final class BatteryHistory {
    private static final String PREFS = "cmkagent_accumeter_v2";

    private static final String K_SAMPLES = "accumeter_capacity_samples";
    private static final String K_CALIBRATED_FULL_MAH = "calibrated_full_mah";
    private static final String K_CALIBRATED_FULL_VOLT = "calibrated_full_volt";
    private static final String K_CALIBRATED_TIMESTAMP = "calibrated_timestamp";

    private static final String K_IS_CHARGING = "active_is_charging";
    private static final String K_SESSION_START_LEVEL = "active_start_level";
    private static final String K_SESSION_START_MAH = "active_start_mah";
    private static final String K_SESSION_LAST_LEVEL = "active_last_level";
    private static final String K_SESSION_LAST_MAH = "active_last_mah";

    private static final int MAX_SESSIONS = 15;
    private static final int MIN_CHARGE_DELTA_PERCENT = 20;

    private BatteryHistory() {}

    public static synchronized void updateChargeSession(
            Context context, int level, String status, double chargeCounterMah, double voltageV) {
        if (context == null || level < 0) return;

        SharedPreferences prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        boolean isCharging = "Charging".equalsIgnoreCase(status);
        boolean wasCharging = prefs.getBoolean(K_IS_CHARGING, false);

        if ((level == 100 || "Full".equalsIgnoreCase(status)) && chargeCounterMah > 2000) {
            prefs.edit()
                    .putFloat(K_CALIBRATED_FULL_MAH, (float) chargeCounterMah)
                    .putFloat(K_CALIBRATED_FULL_VOLT, (float) voltageV)
                    .putLong(K_CALIBRATED_TIMESTAMP, System.currentTimeMillis())
                    .apply();
        }

        if (isCharging && !wasCharging) {
            prefs.edit()
                    .putBoolean(K_IS_CHARGING, true)
                    .putInt(K_SESSION_START_LEVEL, level)
                    .putFloat(K_SESSION_START_MAH, (float) chargeCounterMah)
                    .putInt(K_SESSION_LAST_LEVEL, level)
                    .putFloat(K_SESSION_LAST_MAH, (float) chargeCounterMah)
                    .apply();
            return;
        }

        if (isCharging && wasCharging) {
            prefs.edit()
                    .putInt(K_SESSION_LAST_LEVEL, level)
                    .putFloat(K_SESSION_LAST_MAH, (float) chargeCounterMah)
                    .apply();
            return;
        }

        if (!isCharging && wasCharging) {
            int startLevel = prefs.getInt(K_SESSION_START_LEVEL, -1);
            int lastLevel = prefs.getInt(K_SESSION_LAST_LEVEL, -1);
            double startMah = prefs.getFloat(K_SESSION_START_MAH, -1f);
            double lastMah = prefs.getFloat(K_SESSION_LAST_MAH, -1f);

            int deltaLevel = lastLevel - startLevel;
            double deltaMah = lastMah - startMah;

            if (deltaLevel >= MIN_CHARGE_DELTA_PERCENT && deltaMah > 0) {
                double estimatedSessionFull = (deltaMah / (deltaLevel / 100.0));
                if (estimatedSessionFull >= 800.0 && estimatedSessionFull <= 25000.0) {
                    addSessionSample(prefs, estimatedSessionFull);
                }
            }

            prefs.edit()
                    .putBoolean(K_IS_CHARGING, false)
                    .remove(K_SESSION_START_LEVEL)
                    .remove(K_SESSION_START_MAH)
                    .apply();
        }
    }

    private static void addSessionSample(SharedPreferences prefs, double capacity) {
        List<Double> samples = parseSamples(prefs.getString(K_SAMPLES, ""));
        samples.add(capacity);
        while (samples.size() > MAX_SESSIONS) {
            samples.remove(0);
        }

        StringBuilder sb = new StringBuilder();
        for (double s : samples) {
            if (sb.length() > 0) sb.append(',');
            sb.append(String.format(Locale.US, "%.1f", s));
        }
        prefs.edit().putString(K_SAMPLES, sb.toString()).apply();
    }

    public static double getMedianCapacity(Context context) {
        if (context == null) return Double.NaN;
        SharedPreferences prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        List<Double> samples = parseSamples(prefs.getString(K_SAMPLES, ""));
        if (samples.isEmpty()) return Double.NaN;

        List<Double> sorted = new ArrayList<>(samples);
        Collections.sort(sorted);
        int n = sorted.size();
        if (n % 2 == 1) return sorted.get(n / 2);
        return (sorted.get(n / 2 - 1) + sorted.get(n / 2)) / 2.0;
    }

    public static int getSampleCount(Context context) {
        if (context == null) return 0;
        SharedPreferences prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
        return parseSamples(prefs.getString(K_SAMPLES, "")).size();
    }

    public static double getCalibratedFullChargeMah(Context context) {
        if (context == null) return Double.NaN;
        float val = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .getFloat(K_CALIBRATED_FULL_MAH, -1f);
        return val > 2000 ? val : Double.NaN;
    }

    public static double getCalibratedFullVoltage(Context context) {
        if (context == null) return Double.NaN;
        float val = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
                .getFloat(K_CALIBRATED_FULL_VOLT, -1f);
        return val > 0 ? val : Double.NaN;
    }

    private static List<Double> parseSamples(String raw) {
        List<Double> result = new ArrayList<>();
        if (raw == null || raw.trim().isEmpty()) return result;
        for (String token : raw.split(",")) {
            try {
                double val = Double.parseDouble(token.trim());
                if (val > 0) result.add(val);
            } catch (Exception ignored) {}
        }
        return result;
    }

    public static void clear(Context context) {
        if (context != null) {
            context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().clear().apply();
        }
    }
}
