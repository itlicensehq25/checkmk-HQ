package com.bcp.checkmkagent;

import android.app.ActivityManager;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.net.ConnectivityManager;
import android.net.LinkAddress;
import android.net.LinkProperties;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.net.wifi.WifiInfo;
import android.net.wifi.WifiManager;
import android.os.BatteryManager;
import android.os.Build;
import android.os.Environment;
import android.os.StatFs;
import android.os.SystemClock;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileReader;
import java.lang.reflect.Constructor;
import java.lang.reflect.Method;
import java.net.Inet4Address;
import java.net.NetworkInterface;
import java.util.Collections;
import java.util.Locale;

public final class DeviceMetrics {

    private DeviceMetrics() {}

    public static final class BatteryInfo {
        public int level = -1;
        public double temperatureC = Double.NaN;
        public double voltageV = Double.NaN;
        public String status = "Unknown";
        public String healthStatus = "Good";
        public double chargeCounterMah = Double.NaN;
        public double currentNowMa = Double.NaN;
        public double currentAverageMa = Double.NaN;
        public double designCapacityMah = Double.NaN;
        public String designCapacitySource = "Unavailable";
        public double fullCapacityMah = Double.NaN;
        public double fullChargeVoltageV = Double.NaN;
        public String fullCapacitySource = "Unavailable";
        public boolean fullCapacityEstimated = false;
        public double healthPercent = 100.0;
        public int estimateSamples = 0;
        public int cycleCount = -1;
    }

    public static final class UsageInfo {
        public double totalGb;
        public double freeGb;
        public double usedGb;
        public double usedPercent;
    }

    public static final class WifiStatus {
        public boolean connected;
        public String ssid = "Not Connected";
        public String ip = "N/A";
        public int rssi = Integer.MIN_VALUE;
        public int linkSpeedMbps = -1;
        public int frequencyMhz = -1;
        public String detectionSource = "Unavailable";
        public String detailsSource = "Unavailable";
    }

    public static final class DeviceInfo {
        public String manufacturer;
        public String model;
        public String androidVersion;
        public int sdk;
        public long uptimeMs;
        public String profile;
    }

    public static BatteryInfo readBattery(Context context) {
        BatteryInfo out = new BatteryInfo();
        if (context == null) return out;

        boolean isMt93 = isNewlandMt93();

        Intent battery = null;
        try {
            battery = context.registerReceiver(null, new IntentFilter(Intent.ACTION_BATTERY_CHANGED));
            if (battery != null) {
                int rawLevel = battery.getIntExtra(BatteryManager.EXTRA_LEVEL, -1);
                int scale = battery.getIntExtra(BatteryManager.EXTRA_SCALE, 100);
                if (rawLevel >= 0 && scale > 0) {
                    out.level = (int) Math.round(rawLevel * 100.0 / scale);
                }

                int tempTenths = battery.getIntExtra(BatteryManager.EXTRA_TEMPERATURE, Integer.MIN_VALUE);
                if (tempTenths != Integer.MIN_VALUE && tempTenths != 0) {
                    out.temperatureC = tempTenths / 10.0;
                }

                int voltageMv = battery.getIntExtra(BatteryManager.EXTRA_VOLTAGE, -1);
                if (voltageMv > 0) out.voltageV = voltageMv / 1000.0;

                int status = battery.getIntExtra(BatteryManager.EXTRA_STATUS, BatteryManager.BATTERY_STATUS_UNKNOWN);
                switch (status) {
                    case BatteryManager.BATTERY_STATUS_CHARGING:
                        out.status = "Charging";
                        break;
                    case BatteryManager.BATTERY_STATUS_DISCHARGING:
                        out.status = "Discharging";
                        break;
                    case BatteryManager.BATTERY_STATUS_FULL:
                        out.status = "Full";
                        break;
                    case BatteryManager.BATTERY_STATUS_NOT_CHARGING:
                        out.status = "Not Charging";
                        break;
                    default:
                        out.status = "Unknown";
                }

                int rawHealth = battery.getIntExtra(BatteryManager.EXTRA_HEALTH, BatteryManager.BATTERY_HEALTH_UNKNOWN);
                switch (rawHealth) {
                    case BatteryManager.BATTERY_HEALTH_GOOD:
                        out.healthStatus = "Good";
                        break;
                    case BatteryManager.BATTERY_HEALTH_OVERHEAT:
                        out.healthStatus = "Overheat";
                        break;
                    case BatteryManager.BATTERY_HEALTH_DEAD:
                        out.healthStatus = "Dead";
                        break;
                    case BatteryManager.BATTERY_HEALTH_OVER_VOLTAGE:
                        out.healthStatus = "Over Voltage";
                        break;
                    case BatteryManager.BATTERY_HEALTH_COLD:
                        out.healthStatus = "Cold";
                        break;
                    default:
                        out.healthStatus = "Unknown";
                }
            }
        } catch (Throwable ignored) {}

        try {
            BatteryManager bm = (BatteryManager) context.getSystemService(Context.BATTERY_SERVICE);
            if (bm != null) {
                try {
                    int chargeCounterUah = bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CHARGE_COUNTER);
                    if (validBatteryProperty(chargeCounterUah) && chargeCounterUah > 0) {
                        out.chargeCounterMah = chargeCounterUah / 1000.0;
                    }
                } catch (Throwable ignored) {}

                try {
                    int currentNowUa = bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CURRENT_NOW);
                    if (validBatteryProperty(currentNowUa)) out.currentNowMa = currentNowUa / 1000.0;
                } catch (Throwable ignored) {}

                try {
                    int currentAvgUa = bm.getIntProperty(BatteryManager.BATTERY_PROPERTY_CURRENT_AVERAGE);
                    if (validBatteryProperty(currentAvgUa)) out.currentAverageMa = currentAvgUa / 1000.0;
                } catch (Throwable ignored) {}

                if (Build.VERSION.SDK_INT >= 34) {
                    try {
                        int cycles = bm.getIntProperty(7);
                        if (validBatteryProperty(cycles) && cycles >= 0) {
                            out.cycleCount = cycles;
                        }
                    } catch (Throwable ignored) {}
                }
            }
        } catch (Throwable ignored) {}

        if (out.cycleCount < 0) {
            String[] cyclePaths = {
                    "/sys/class/power_supply/battery/cycle_count",
                    "/sys/class/power_supply/bms/cycle_count",
                    "/sys/class/power_supply/battery/battery_cycle",
                    "/sys/devices/platform/charger/power_supply/battery/cycle_count"
            };
            for (String path : cyclePaths) {
                try {
                    Double val = readNumber(path);
                    if (val != null && val >= 0) {
                        out.cycleCount = val.intValue();
                        break;
                    }
                } catch (Throwable ignored) {}
            }
        }

        // 1. Tentukan Design Capacity secara dinamis dari sistem Android
        try {
            double manual = AgentConfig.getDesignCapacityMah(context);
            if (isPositive(manual)) {
                out.designCapacityMah = manual;
                out.designCapacitySource = "Manual Configuration";
            } else {
                double profileVal = readPowerProfileCapacityMah(context);
                if (isPositive(profileVal)) {
                    out.designCapacityMah = profileVal;
                    out.designCapacitySource = "Android System (" + Math.round(profileVal) + " mAh)";
                } else {
                    out.designCapacityMah = isMt93 ? 4800.0 : 5000.0;
                    out.designCapacitySource = "Factory Spec (" + Math.round(out.designCapacityMah) + " mAh)";
                }
            }
        } catch (Throwable ignored) {
            out.designCapacityMah = isMt93 ? 4800.0 : 5000.0;
            out.designCapacitySource = "Factory Spec";
        }

        // 2. Evaluasi Muatan Saat Ini (Current Charge)
        if (!isPositive(out.chargeCounterMah) && out.level >= 0) {
            double referenceFull = isMt93 ? 2946.0 : out.designCapacityMah;
            out.chargeCounterMah = Math.round(referenceFull * (out.level / 100.0));
        }

        // Simpan sesi pengisian untuk tracking riwayat
        BatteryHistory.updateChargeSession(context, out.level, out.status, out.chargeCounterMah, out.voltageV);
        out.estimateSamples = BatteryHistory.getSampleCount(context);

        // 3. Logika Evaluasi Kesehatan: Terpisah Khusus Newland MT93 vs Perangkat Normal
        if (isMt93) {
            // =========================================================================
            // KHUSUS NEWLAND MT93 (Mengatasi skala virtual firmware 2946 mAh)
            // =========================================================================
            final double MT93_FULL_SCALE = 2946.0;

            if (out.level == 100 || "Full".equalsIgnoreCase(out.status)) {
                out.fullCapacityMah = MT93_FULL_SCALE;
                out.fullChargeVoltageV = !Double.isNaN(out.voltageV) ? out.voltageV : 4.34;
                out.healthPercent = 100.0;
                out.fullCapacitySource = "100% Full Cut-off (2946 mAh)";
            } else if (out.level >= 15 && isPositive(out.chargeCounterMah)) {
                out.fullCapacityMah = out.chargeCounterMah / (out.level / 100.0);
                out.healthPercent = Math.min(100.0, (out.fullCapacityMah / MT93_FULL_SCALE) * 100.0);
                out.fullCapacitySource = "Hardware Normal (" + out.level + "% State)";
            } else {
                out.fullCapacityMah = MT93_FULL_SCALE;
                out.healthPercent = 100.0;
                out.fullCapacitySource = "System Baseline";
            }
        } else {
            // =========================================================================
            // PERANGKAT NORMAL (Smartphone Xiaomi, Samsung, dsb.)
            // =========================================================================
            if (out.level == 100 || "Full".equalsIgnoreCase(out.status)) {
                out.fullCapacityMah = (isPositive(out.chargeCounterMah) && out.chargeCounterMah > 2000.0)
                        ? out.chargeCounterMah : out.designCapacityMah;
                out.fullChargeVoltageV = !Double.isNaN(out.voltageV) ? out.voltageV : 4.35;
                out.healthPercent = Math.min(100.0, (out.fullCapacityMah / out.designCapacityMah) * 100.0);
                out.fullCapacitySource = "100% Full Cut-off";
            } else if (out.level >= 15 && isPositive(out.chargeCounterMah)) {
                out.fullCapacityMah = out.chargeCounterMah / (out.level / 100.0);
                out.healthPercent = Math.min(100.0, (out.fullCapacityMah / out.designCapacityMah) * 100.0);
                out.fullCapacitySource = "Dynamic Estimate (" + out.level + "% State)";
                out.fullCapacityEstimated = true;
            } else {
                out.fullCapacityMah = out.designCapacityMah;
                out.healthPercent = 100.0;
                out.fullCapacitySource = "System Baseline";
            }
        }

        return out;
    }

    public static UsageInfo readRam(Context context) {
        ActivityManager am = (ActivityManager) context.getSystemService(Context.ACTIVITY_SERVICE);
        ActivityManager.MemoryInfo mi = new ActivityManager.MemoryInfo();
        if (am != null) am.getMemoryInfo(mi);

        UsageInfo out = new UsageInfo();
        out.totalGb = bytesToGb(mi.totalMem);
        out.freeGb = bytesToGb(mi.availMem);
        out.usedGb = Math.max(0, out.totalGb - out.freeGb);
        out.usedPercent = out.totalGb > 0 ? (out.usedGb / out.totalGb * 100.0) : 0.0;
        return out;
    }

    public static UsageInfo readStorage() {
        StatFs stat = new StatFs(Environment.getDataDirectory().getAbsolutePath());
        UsageInfo out = new UsageInfo();
        out.totalGb = bytesToGb(stat.getTotalBytes());
        out.freeGb = bytesToGb(stat.getAvailableBytes());
        out.usedGb = Math.max(0, out.totalGb - out.freeGb);
        out.usedPercent = out.totalGb > 0 ? (out.usedGb / out.totalGb * 100.0) : 0.0;
        return out;
    }

    @SuppressWarnings("deprecation")
    public static WifiStatus readWifi(Context context) {
        WifiStatus out = new WifiStatus();
        out.ip = getLocalIpv4();

        WifiManager wm = null;
        try {
            wm = (WifiManager) context.getApplicationContext()
                    .getSystemService(Context.WIFI_SERVICE);
            ConnectivityManager cm = (ConnectivityManager) context
                    .getSystemService(Context.CONNECTIVITY_SERVICE);

            Network wifiNetwork = null;
            NetworkCapabilities wifiCaps = null;

            if (cm != null) {
                Network[] networks = cm.getAllNetworks();
                if (networks != null) {
                    for (Network network : networks) {
                        NetworkCapabilities caps = cm.getNetworkCapabilities(network);
                        if (caps != null && caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) {
                            wifiNetwork = network;
                            wifiCaps = caps;
                            break;
                        }
                    }
                }
            }

            if (wifiNetwork != null) {
                out.connected = true;
                out.detectionSource = "ConnectivityManager Wi-Fi transport";

                LinkProperties lp = cm.getLinkProperties(wifiNetwork);
                String ip = ipv4FromLinkProperties(lp);
                if (ip != null) out.ip = ip;

                WifiInfo info = wifiInfoFromCapabilities(wifiCaps);
                if (info != null) {
                    fillWifiInfo(out, info, "NetworkCapabilities WifiInfo");
                }
            }

            if (!out.connected) {
                String wlanIp = getWifiInterfaceIpv4();
                if (wlanIp != null) {
                    out.connected = true;
                    out.ip = wlanIp;
                    out.detectionSource = "wlan interface";
                }
            }

            if (wm != null && wm.isWifiEnabled()) {
                WifiInfo legacy = wm.getConnectionInfo();
                if (legacy != null) {
                    if (!out.connected && hasUsefulWifiInfo(legacy)) {
                        out.connected = true;
                        out.detectionSource = "WifiManager connection info";
                    }
                    if (out.connected && "Unavailable".equals(out.detailsSource)) {
                        fillWifiInfo(out, legacy, "WifiManager connection info");
                    }
                }
            }

            if (out.connected && "Not Connected".equals(out.ssid)) {
                out.ssid = "Connected (SSID restricted by Android)";
            }
        } catch (SecurityException e) {
            String wlanIp = getWifiInterfaceIpv4();
            if (wlanIp != null) {
                out.connected = true;
                out.ip = wlanIp;
                out.detectionSource = "wlan interface (permission fallback)";
                out.ssid = "Connected (permission restricted)";
            }
        } catch (Exception ignored) {
            String wlanIp = getWifiInterfaceIpv4();
            if (wlanIp != null) {
                out.connected = true;
                out.ip = wlanIp;
                out.detectionSource = "wlan interface (fallback)";
                out.ssid = "Connected (details unavailable)";
            }
        }
        return out;
    }

    private static WifiInfo wifiInfoFromCapabilities(NetworkCapabilities caps) {
        if (caps == null || Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return null;
        try {
            Object transportInfo = caps.getTransportInfo();
            return transportInfo instanceof WifiInfo ? (WifiInfo) transportInfo : null;
        } catch (Exception ignored) {
            return null;
        }
    }

    private static void fillWifiInfo(WifiStatus out, WifiInfo info, String source) {
        if (info == null) return;
        out.detailsSource = source;

        String ssid = info.getSSID();
        if (ssid != null && !ssid.isEmpty()
                && !"<unknown ssid>".equalsIgnoreCase(ssid)
                && !WifiManager.UNKNOWN_SSID.equals(ssid)) {
            if (ssid.startsWith("\"") && ssid.endsWith("\"") && ssid.length() >= 2) {
                ssid = ssid.substring(1, ssid.length() - 1);
            }
            out.ssid = ssid;
        }

        int rssi = info.getRssi();
        if (isUsableRssi(rssi)) {
            out.rssi = rssi;
        }

        int speed = info.getLinkSpeed();
        if (speed >= 0) out.linkSpeedMbps = speed;

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP) {
            int frequency = info.getFrequency();
            if (frequency > 0) out.frequencyMhz = frequency;
        }
    }

    private static boolean hasUsefulWifiInfo(WifiInfo info) {
        if (info == null) return false;
        int rssi = info.getRssi();
        if (isUsableRssi(rssi)) return true;
        if (info.getLinkSpeed() > 0) return true;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.LOLLIPOP && info.getFrequency() > 0) return true;
        String ssid = info.getSSID();
        return ssid != null && !ssid.isEmpty()
                && !"<unknown ssid>".equalsIgnoreCase(ssid)
                && !WifiManager.UNKNOWN_SSID.equals(ssid);
    }

    private static String ipv4FromLinkProperties(LinkProperties lp) {
        if (lp == null) return null;
        for (LinkAddress la : lp.getLinkAddresses()) {
            if (la.getAddress() instanceof Inet4Address && !la.getAddress().isLoopbackAddress()) {
                String ip = la.getAddress().getHostAddress();
                if (ip != null && !ip.startsWith("169.254.")) return ip;
            }
        }
        return null;
    }

    private static String getWifiInterfaceIpv4() {
        try {
            for (NetworkInterface ni : Collections.list(NetworkInterface.getNetworkInterfaces())) {
                String name = ni.getName() == null ? "" : ni.getName().toLowerCase(Locale.US);
                if (!ni.isUp() || ni.isLoopback()
                        || !(name.startsWith("wlan") || name.startsWith("wifi"))) {
                    continue;
                }
                for (java.net.InetAddress addr : Collections.list(ni.getInetAddresses())) {
                    if (addr instanceof Inet4Address && !addr.isLoopbackAddress()) {
                        String ip = addr.getHostAddress();
                        if (ip != null && !ip.startsWith("169.254.")) return ip;
                    }
                }
            }
        } catch (Exception ignored) {}
        return null;
    }

    public static DeviceInfo readDeviceInfo() {
        DeviceInfo out = new DeviceInfo();
        out.manufacturer = safe(Build.MANUFACTURER);
        out.model = safe(Build.MODEL);
        out.androidVersion = safe(Build.VERSION.RELEASE);
        out.sdk = Build.VERSION.SDK_INT;
        out.uptimeMs = SystemClock.elapsedRealtime();
        out.profile = out.manufacturer + " " + out.model;
        return out;
    }

    public static String getLocalIpv4() {
        try {
            for (NetworkInterface ni : Collections.list(NetworkInterface.getNetworkInterfaces())) {
                if (!ni.isUp() || ni.isLoopback()) continue;
                for (java.net.InetAddress addr : Collections.list(ni.getInetAddresses())) {
                    if (addr instanceof Inet4Address && !addr.isLoopbackAddress()) {
                        String ip = addr.getHostAddress();
                        if (ip != null && !ip.startsWith("169.254.")) return ip;
                    }
                }
            }
        } catch (Exception ignored) {}
        return "N/A";
    }

    public static boolean isNewlandMt93() {
        String joined = (safe(Build.MANUFACTURER) + " " + safe(Build.MODEL) + " "
                + safe(Build.PRODUCT) + " " + safe(Build.DEVICE)).toUpperCase(Locale.US);
        return joined.contains("NEWLAND") || joined.contains("MT93") || joined.contains("NLS-MT93");
    }

    private static boolean isUsableRssi(int rssi) {
        return rssi > -127 && rssi <= 0;
    }

    private static boolean validBatteryProperty(int value) {
        return value != Integer.MIN_VALUE && value != Integer.MAX_VALUE;
    }

    private static Double readNumber(String path) {
        try {
            File f = new File(path);
            if (!f.isFile() || !f.canRead()) return null;
            try (BufferedReader reader = new BufferedReader(new FileReader(f))) {
                String line = reader.readLine();
                if (line == null) return null;
                return Double.parseDouble(line.trim());
            }
        } catch (Throwable ignored) {
            return null;
        }
    }

    private static double readPowerProfileCapacityMah(Context context) {
        try {
            Class<?> clazz = Class.forName("com.android.internal.os.PowerProfile");
            Constructor<?> ctor = clazz.getConstructor(Context.class);
            Object profile = ctor.newInstance(context);
            Method method = clazz.getMethod("getBatteryCapacity");
            Object value = method.invoke(profile);
            if (value instanceof Double) {
                double mah = (Double) value;
                if (mah >= 500.0 && mah <= 30000.0) return mah;
            }
        } catch (Throwable ignored) {}
        return Double.NaN;
    }

    private static boolean isPositive(double value) {
        return !Double.isNaN(value) && !Double.isInfinite(value) && value > 0;
    }

    private static double bytesToGb(long bytes) {
        return bytes / 1024.0 / 1024.0 / 1024.0;
    }

    private static String safe(String value) {
        return value == null || value.trim().isEmpty() ? "Unknown" : value.trim();
    }

    public static String fmt1(double value) {
        return String.format(Locale.US, "%.1f", value);
    }

    public static String fmt2(double value) {
        return String.format(Locale.US, "%.2f", value);
    }
}
