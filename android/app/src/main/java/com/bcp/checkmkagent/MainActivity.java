package com.bcp.checkmkagent;

import android.Manifest;
import android.app.Activity;
import android.app.AlertDialog;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.content.res.ColorStateList;
import android.graphics.Color;
import android.graphics.Typeface;
import android.graphics.drawable.GradientDrawable;
import android.location.LocationManager;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;
import android.os.PowerManager;
import android.provider.Settings;
import android.text.InputType;
import android.view.Gravity;
import android.view.View;
import android.view.ViewGroup;
import android.widget.Button;
import android.widget.CheckBox;
import android.widget.EditText;
import android.widget.ImageView;
import android.widget.LinearLayout;
import android.widget.ProgressBar;
import android.widget.ScrollView;
import android.widget.TextView;
import android.widget.Toast;

import java.text.SimpleDateFormat;
import java.util.ArrayList;
import java.util.Date;
import java.util.List;
import java.util.Locale;

public class MainActivity extends Activity {
    private static final int C_BG = Color.rgb(15, 23, 32);
    private static final int C_CARD = Color.rgb(24, 35, 46);
    private static final int C_CARD_ALT = Color.rgb(20, 30, 40);
    private static final int C_TEXT = Color.rgb(244, 247, 249);
    private static final int C_MUTED = Color.rgb(170, 183, 195);
    private static final int C_GREEN = Color.rgb(91, 207, 126);
    private static final int C_WARN = Color.rgb(246, 200, 95);
    private static final int C_CRIT = Color.rgb(230, 106, 106);
    private static final int C_LINE = Color.rgb(45, 61, 75);

    private EditText hostnameInput;
    private EditText portInput;
    private EditText designCapacityInput;
    private EditText allowedServerInput;
    private CheckBox autoStartInput;
    private CheckBox pushEnabledInput;
    private EditText pushUrlInput;
    private EditText pushTokenInput;
    private EditText pushIntervalInput;

    private Section agentSection;
    private Section transportSection;
    private Section batterySection;
    private Section systemSection;
    private Section networkSection;
    private Section deviceSection;
    private Section settingsSection;
    private Section diagnosticsSection;

    private TextView agentBadge;
    private TextView agentText;
    private TextView batteryHeadline;
    private TextView batteryText;
    private TextView systemText;
    private TextView networkText;
    private TextView deviceText;
    private TextView diagnosticsText;
    private ProgressBar batteryProgress;

    private final List<Section> allSections = new ArrayList<>();

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        getWindow().setStatusBarColor(C_BG);
        getWindow().setNavigationBarColor(C_BG);
        setContentView(buildUi());
        loadConfig();
        requestRuntimePermissionsIfNeeded();
        updateDashboard();
    }

    @Override
    protected void onResume() {
        super.onResume();
        if (agentText != null) updateDashboard();
    }

    private ScrollView buildUi() {
        ScrollView scroll = new ScrollView(this);
        scroll.setFillViewport(true);
        scroll.setBackgroundColor(C_BG);

        LinearLayout root = new LinearLayout(this);
        root.setOrientation(LinearLayout.VERTICAL);
        root.setPadding(dp(16), dp(18), dp(16), dp(28));
        scroll.addView(root, new ScrollView.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT));

        root.addView(buildHeader());
        root.addView(space(12));
        root.addView(buildSectionControls(), matchWrapMargin(0, 0, 0, 12));

        agentSection = section("AGENT", "Pull listener & connection status", false);
        agentBadge = badge("STARTING", C_WARN);
        agentSection.content.addView(agentBadge, wrap());
        agentText = bodyText();
        agentText.setPadding(0, dp(12), 0, 0);
        agentSection.content.addView(agentText, wrap());
        root.addView(agentSection.card, matchWrapMargin(0, 0, 0, 12));

        transportSection = section("HYBRID TRANSPORT", "Pull primary + push warm backup", false);
        TextView transportHelp = bodyText();
        transportHelp.setText("Pull TCP/6556 tetap menjadi jalur utama. Push hanya menjaga salinan data terbaru di receiver sebagai jalur cadangan.");
        transportHelp.setTextColor(C_MUTED);
        transportSection.content.addView(transportHelp, wrap());
        root.addView(transportSection.card, matchWrapMargin(0, 0, 0, 12));

        batterySection = section("BATTERY", "Level, health estimate & thermal status", false);
        batteryHeadline = new TextView(this);
        batteryHeadline.setTextColor(C_TEXT);
        batteryHeadline.setTextSize(25);
        batteryHeadline.setTypeface(Typeface.DEFAULT_BOLD);
        batterySection.content.addView(batteryHeadline, wrap());

        batteryProgress = new ProgressBar(this, null, android.R.attr.progressBarStyleHorizontal);
        batteryProgress.setMax(100);
        batteryProgress.setProgressTintList(ColorStateList.valueOf(C_GREEN));
        batteryProgress.setProgressBackgroundTintList(ColorStateList.valueOf(C_LINE));
        LinearLayout.LayoutParams bp = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, dp(8));
        bp.setMargins(0, dp(10), 0, dp(10));
        batterySection.content.addView(batteryProgress, bp);

        batteryText = bodyText();
        batterySection.content.addView(batteryText, wrap());
        root.addView(batterySection.card, matchWrapMargin(0, 0, 0, 12));

        systemSection = section("SYSTEM", "RAM & internal storage", false);
        systemText = bodyText();
        systemSection.content.addView(systemText, wrap());
        root.addView(systemSection.card, matchWrapMargin(0, 0, 0, 12));

        networkSection = section("NETWORK", "Network status & permissions", false);
        networkText = bodyText();
        networkSection.content.addView(networkText, wrap());

        LinearLayout netActions = new LinearLayout(this);
        netActions.setOrientation(LinearLayout.HORIZONTAL);
        Button permissionButton = actionButton("APP PERMISSIONS", C_CARD_ALT, C_TEXT);
        permissionButton.setOnClickListener(v -> openAppSettings());
        Button batteryOptButton = actionButton("BATTERY UNRESTRICTED", C_CARD_ALT, C_TEXT);
        batteryOptButton.setOnClickListener(v -> requestIgnoreBatteryOptimizations());
        netActions.addView(permissionButton, weightButton());
        LinearLayout.LayoutParams secondP = weightButton();
        secondP.setMargins(dp(8), 0, 0, 0);
        netActions.addView(batteryOptButton, secondP);
        networkSection.content.addView(netActions, matchWrapMargin(0, 12, 0, 0));
        root.addView(networkSection.card, matchWrapMargin(0, 0, 0, 12));

        deviceSection = section("DEVICE", "Hardware & Android profile", false);
        deviceText = bodyText();
        deviceSection.content.addView(deviceText, wrap());
        root.addView(deviceSection.card, matchWrapMargin(0, 0, 0, 12));

        settingsSection = section("SETTINGS", "Tap to configure agent", false);
        hostnameInput = input(settingsSection.content, "Hostname Checkmk", InputType.TYPE_CLASS_TEXT,
                "Contoh: PDA-10-FAUZI");
        portInput = input(settingsSection.content, "TCP Port", InputType.TYPE_CLASS_NUMBER, "6556");
        designCapacityInput = input(settingsSection.content,
                "Design Capacity (mAh, 0 = auto)",
                InputType.TYPE_CLASS_NUMBER | InputType.TYPE_NUMBER_FLAG_DECIMAL,
                "0 = Otomatis (MT93 BTY95L = 5000 mAh)");
        allowedServerInput = input(settingsSection.content,
                "Allowed Checkmk Server IP",
                InputType.TYPE_CLASS_TEXT,
                "Kosong = semua IP; contoh: 192.168.55.112");

        pushEnabledInput = new CheckBox(this);
        pushEnabledInput.setText("Aktifkan PUSH backup (Hybrid)");
        pushEnabledInput.setTextColor(C_TEXT);
        pushEnabledInput.setButtonTintList(ColorStateList.valueOf(C_GREEN));
        pushEnabledInput.setPadding(0, dp(6), 0, dp(6));
        settingsSection.content.addView(pushEnabledInput, matchWrap());

        pushUrlInput = input(settingsSection.content,
                "Push Receiver URL",
                InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_URI,
                "Contoh: http://192.168.55.112:18080/api/v1/agent");
        pushTokenInput = input(settingsSection.content,
                "Push Token",
                InputType.TYPE_CLASS_TEXT | InputType.TYPE_TEXT_VARIATION_PASSWORD,
                "Bearer token receiver (opsional untuk test)");
        pushIntervalInput = input(settingsSection.content,
                "Push Interval (detik, minimal 60)",
                InputType.TYPE_CLASS_NUMBER,
                "300");

        Button testPush = actionButton("TEST PUSH NOW", C_CARD_ALT, C_TEXT);
        testPush.setOnClickListener(v -> testPushNow());
        settingsSection.content.addView(testPush, matchWrapMargin(0, 2, 0, 8));

        autoStartInput = new CheckBox(this);
        autoStartInput.setText("Start agent otomatis setelah boot");
        autoStartInput.setTextColor(C_TEXT);
        autoStartInput.setButtonTintList(ColorStateList.valueOf(C_GREEN));
        autoStartInput.setPadding(0, dp(6), 0, dp(8));
        settingsSection.content.addView(autoStartInput, matchWrap());

        Button start = actionButton("SAVE & START AGENT", C_GREEN, Color.rgb(10, 32, 18));
        start.setOnClickListener(v -> saveAndStart());
        settingsSection.content.addView(start, matchWrapMargin(0, 4, 0, 8));

        LinearLayout actions = new LinearLayout(this);
        actions.setOrientation(LinearLayout.HORIZONTAL);
        Button refresh = actionButton("REFRESH", C_CARD_ALT, C_TEXT);
        refresh.setOnClickListener(v -> updateDashboard());
        Button preview = actionButton("AGENT OUTPUT", C_CARD_ALT, C_TEXT);
        preview.setOnClickListener(v -> showAgentOutput());
        actions.addView(refresh, weightButton());
        LinearLayout.LayoutParams second = weightButton();
        second.setMargins(dp(8), 0, 0, 0);
        actions.addView(preview, second);
        settingsSection.content.addView(actions, matchWrapMargin(0, 0, 0, 8));

        Button stop = actionButton("STOP AGENT", Color.rgb(82, 42, 47), Color.rgb(255, 205, 210));
        stop.setOnClickListener(v -> {
            stopService(new Intent(this, CheckmkAgentService.class));
            AgentStats.recordStop(this);
            Toast.makeText(this, "Agent dihentikan", Toast.LENGTH_SHORT).show();
            agentText.postDelayed(this::updateDashboard, 250);
        });
        settingsSection.content.addView(stop, matchWrap());
        root.addView(settingsSection.card, matchWrapMargin(0, 0, 0, 12));

        diagnosticsSection = section("DIAGNOSTICS", "Status & counter", false);
        diagnosticsText = bodyText();
        diagnosticsText.setTextIsSelectable(true);
        diagnosticsSection.content.addView(diagnosticsText, wrap());
        root.addView(diagnosticsSection.card, matchWrapMargin(0, 0, 0, 12));

        TextView footer = new TextView(this);
        footer.setText("Universal Android Agent • Checkmk Hybrid\nDibuat oleh IT OPS HQEJBNT");
        footer.setTextColor(C_MUTED);
        footer.setTextSize(12);
        footer.setGravity(Gravity.CENTER);
        footer.setPadding(dp(12), dp(4), dp(12), 0);
        root.addView(footer, matchWrap());

        return scroll;
    }

    private View buildHeader() {
        LinearLayout header = new LinearLayout(this);
        header.setOrientation(LinearLayout.HORIZONTAL);
        header.setGravity(Gravity.CENTER_VERTICAL);

        ImageView icon = new ImageView(this);
        icon.setImageResource(R.drawable.ic_cmkagent);
        LinearLayout.LayoutParams ip = new LinearLayout.LayoutParams(dp(58), dp(58));
        ip.setMargins(0, 0, dp(14), 0);
        header.addView(icon, ip);

        LinearLayout text = new LinearLayout(this);
        text.setOrientation(LinearLayout.VERTICAL);
        TextView title = new TextView(this);
        title.setText("cmkagent");
        title.setTextColor(C_TEXT);
        title.setTextSize(29);
        title.setTypeface(Typeface.DEFAULT_BOLD);
        TextView subtitle = new TextView(this);
        subtitle.setText("Checkmk Universal Android Agent  •  v" + CheckmkOutput.VERSION);
        subtitle.setTextColor(C_MUTED);
        subtitle.setTextSize(13);
        text.addView(title);
        text.addView(subtitle);
        header.addView(text, new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1f));
        return header;
    }

    private View buildSectionControls() {
        LinearLayout row = new LinearLayout(this);
        row.setOrientation(LinearLayout.HORIZONTAL);
        Button expand = actionButton("EXPAND ALL", C_CARD_ALT, C_TEXT);
        Button collapse = actionButton("COLLAPSE ALL", C_CARD_ALT, C_TEXT);
        expand.setOnClickListener(v -> setAllSections(true));
        collapse.setOnClickListener(v -> setAllSections(false));
        row.addView(expand, weightButton());
        LinearLayout.LayoutParams cp = weightButton();
        cp.setMargins(dp(8), 0, 0, 0);
        row.addView(collapse, cp);
        return row;
    }

    private Section section(String titleText, String subtitleText, boolean expanded) {
        Section s = new Section();
        s.card = new LinearLayout(this);
        s.card.setOrientation(LinearLayout.VERTICAL);
        s.card.setPadding(dp(16), dp(13), dp(16), dp(14));
        s.card.setBackground(rounded(C_CARD, 16, C_LINE, 1));

        LinearLayout header = new LinearLayout(this);
        header.setOrientation(LinearLayout.HORIZONTAL);
        header.setGravity(Gravity.CENTER_VERTICAL);
        header.setPadding(0, dp(2), 0, dp(2));

        LinearLayout labels = new LinearLayout(this);
        labels.setOrientation(LinearLayout.VERTICAL);
        TextView title = new TextView(this);
        title.setText(titleText);
        title.setTextColor(C_GREEN);
        title.setTextSize(13);
        title.setTypeface(Typeface.DEFAULT_BOLD);
        TextView subtitle = new TextView(this);
        subtitle.setText(subtitleText);
        subtitle.setTextColor(C_MUTED);
        subtitle.setTextSize(12);
        subtitle.setPadding(0, dp(2), 0, 0);
        labels.addView(title, wrap());
        labels.addView(subtitle, wrap());
        header.addView(labels, new LinearLayout.LayoutParams(0,
                ViewGroup.LayoutParams.WRAP_CONTENT, 1f));

        s.arrow = new TextView(this);
        s.arrow.setTextColor(C_MUTED);
        s.arrow.setTextSize(20);
        s.arrow.setGravity(Gravity.CENTER);
        s.arrow.setPadding(dp(12), 0, dp(4), 0);
        header.addView(s.arrow, new LinearLayout.LayoutParams(dp(44), dp(44)));
        s.card.addView(header, matchWrap());

        s.summary = new TextView(this);
        s.summary.setTextColor(C_TEXT);
        s.summary.setTextSize(14);
        s.summary.setTypeface(Typeface.DEFAULT_BOLD);
        s.summary.setPadding(0, dp(8), 0, dp(2));
        s.card.addView(s.summary, matchWrap());

        s.content = new LinearLayout(this);
        s.content.setOrientation(LinearLayout.VERTICAL);
        s.content.setPadding(0, dp(12), 0, 0);
        s.card.addView(s.content, matchWrap());

        View.OnClickListener toggle = v -> setSectionExpanded(s, !s.expanded);
        header.setOnClickListener(toggle);
        s.summary.setOnClickListener(toggle);
        s.card.setClickable(true);
        s.card.setFocusable(true);

        allSections.add(s);
        setSectionExpanded(s, expanded);
        return s;
    }

    private void setSectionExpanded(Section s, boolean expanded) {
        s.expanded = expanded;
        s.content.setVisibility(expanded ? View.VISIBLE : View.GONE);
        s.arrow.setText(expanded ? "▾" : "▸");
    }

    private void setAllSections(boolean expanded) {
        for (Section s : allSections) setSectionExpanded(s, expanded);
    }

    private void loadConfig() {
        hostnameInput.setText(AgentConfig.getHostname(this));
        portInput.setText(String.valueOf(AgentConfig.getPort(this)));
        double design = AgentConfig.getDesignCapacityMah(this);
        designCapacityInput.setText(design > 0
                ? String.format(Locale.US, "%.0f", design) : "0");
        allowedServerInput.setText(AgentConfig.getAllowedServer(this));
        pushEnabledInput.setChecked(AgentConfig.isPushEnabled(this));
        pushUrlInput.setText(AgentConfig.getPushUrl(this));
        pushTokenInput.setText(AgentConfig.getPushToken(this));
        pushIntervalInput.setText(String.valueOf(AgentConfig.getPushIntervalSec(this)));
        autoStartInput.setChecked(AgentConfig.isAutoStart(this));
    }

    private boolean saveConfigOnly() {
        try {
            String hostname = hostnameInput.getText().toString().trim();
            int port = Integer.parseInt(portInput.getText().toString().trim());
            String designRaw = designCapacityInput.getText().toString().trim();
            double design = designRaw.isEmpty() ? 0.0 : Double.parseDouble(designRaw);
            String allowed = allowedServerInput.getText().toString().trim();
            boolean pushEnabled = pushEnabledInput.isChecked();
            String pushUrl = pushUrlInput.getText().toString().trim();
            String pushToken = pushTokenInput.getText().toString().trim();
            String pushIntervalRaw = pushIntervalInput.getText().toString().trim();
            int pushInterval = pushIntervalRaw.isEmpty() ? 300 : Integer.parseInt(pushIntervalRaw);
            if (port < 1 || port > 65535) throw new IllegalArgumentException("Port tidak valid");
            if (design < 0 || design > 50000) throw new IllegalArgumentException("Design capacity tidak valid");
            if (pushInterval < 60 || pushInterval > 86400) throw new IllegalArgumentException("Push interval harus 60-86400 detik");
            if (pushEnabled && !pushUrl.isEmpty()
                    && !(pushUrl.startsWith("http://") || pushUrl.startsWith("https://"))) {
                throw new IllegalArgumentException("Push URL harus dimulai http:// atau https://");
            }
            AgentConfig.save(this, hostname, port, design, autoStartInput.isChecked(), allowed,
                    pushEnabled, pushUrl, pushToken, pushInterval);
            return true;
        } catch (Exception e) {
            Toast.makeText(this, "Konfigurasi tidak valid: " + e.getMessage(), Toast.LENGTH_LONG).show();
            return false;
        }
    }

    private void saveAndStart() {
        if (!saveConfigOnly()) return;
        stopService(new Intent(this, CheckmkAgentService.class));
        Intent service = new Intent(this, CheckmkAgentService.class);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) startForegroundService(service);
        else startService(service);
        Toast.makeText(this, "cmkagent berjalan", Toast.LENGTH_SHORT).show();
        agentText.postDelayed(this::updateDashboard, 500);
    }

    private void updateDashboard() {
        DeviceMetrics.BatteryInfo b = DeviceMetrics.readBattery(this);
        DeviceMetrics.UsageInfo ram = DeviceMetrics.readRam(this);
        DeviceMetrics.UsageInfo storage = DeviceMetrics.readStorage();
        DeviceMetrics.WifiStatus wifi = DeviceMetrics.readWifi(this);
        DeviceMetrics.DeviceInfo device = DeviceMetrics.readDeviceInfo();
        AgentStats.Snapshot stats = AgentStats.read(this);

        String localIp = DeviceMetrics.getLocalIpv4();
        String lastPull = stats.lastPullMs > 0 ? formatDate(stats.lastPullMs) : "Belum ada";
        String allow = AgentConfig.getAllowedServer(this);
        if (allow.isEmpty()) allow = "Any source";

        agentSection.summary.setText((stats.running ? "RUNNING" : "STOPPED")
                + "  •  " + AgentConfig.getHostname(this) + "  •  " + localIp);
        agentBadge.setText(stats.running ? "● AGENT RUNNING" : "● AGENT STOPPED");
        styleBadge(agentBadge, stats.running ? C_GREEN : C_CRIT);
        agentText.setText(
                "Hostname     : " + AgentConfig.getHostname(this) + "\n"
                        + "Listen       : 0.0.0.0:" + AgentConfig.getPort(this) + "\n"
                        + "Device IP    : " + localIp + "\n"
                        + "Last pull    : " + lastPull + "\n"
                        + "Last client  : " + stats.lastClient + "\n"
                        + "Allowed IP   : " + allow + "\n"
                        + "Mode         : HYBRID (PULL primary + PUSH backup)"
        );

        String pushUrl = AgentConfig.getPushUrl(this);
        boolean pushConfigured = AgentConfig.isPushConfigured(this);
        String lastPush = stats.lastPushMs > 0 ? formatDate(stats.lastPushMs) : "Belum ada";
        String pushState = !pushConfigured ? "NOT CONFIGURED"
                : stats.lastPushMs <= 0 ? "WAITING"
                : stats.lastPushOk ? "OK" : "FAILED";
        transportSection.summary.setText("PULL primary  •  PUSH " + pushState
                + "  •  " + AgentConfig.getPushIntervalSec(this) + "s");
        TextView transportBody = ensureTransportBody();
        transportBody.setText(
                "Primary        : PULL TCP/" + AgentConfig.getPort(this) + "\n"
                        + "Backup         : PUSH HTTP(S)\n"
                        + "Receiver       : " + (pushUrl.isEmpty() ? "Not configured" : pushUrl) + "\n"
                        + "Interval       : " + AgentConfig.getPushIntervalSec(this) + " sec\n"
                        + "Last push      : " + lastPush + "\n"
                        + "Last result    : " + pushState + "\n"
                        + "HTTP code      : " + (stats.lastPushCode > 0 ? stats.lastPushCode : "N/A") + "\n"
                        + "Detail         : " + stats.lastPushMessage + "\n"
                        + "Push success   : " + stats.pushSuccesses + "\n"
                        + "Push failures  : " + stats.pushFailures
        );

        int level = Math.max(0, b.level);
        int batteryColor = level < 15 ? C_CRIT : level < 30 ? C_WARN : C_GREEN;
        batteryProgress.setProgress(level);
        batteryProgress.setProgressTintList(ColorStateList.valueOf(batteryColor));
        batteryHeadline.setText((b.level >= 0 ? b.level + "%" : "N/A") + "  •  " + b.status);
        batteryHeadline.setTextColor(batteryColor);

        String health = Double.isNaN(b.healthPercent) ? "N/A"
                : String.format(Locale.US, "%.1f%%", b.healthPercent);
        String full = Double.isNaN(b.fullCapacityMah) ? "N/A"
                : Math.round(b.fullCapacityMah) + " mAh";
        String design = Double.isNaN(b.designCapacityMah) ? "N/A"
                : Math.round(b.designCapacityMah) + " mAh";
        String temp = Double.isNaN(b.temperatureC) ? "N/A"
                : String.format(Locale.US, "%.1f C", b.temperatureC);
        String voltage = Double.isNaN(b.voltageV) ? "N/A"
                : String.format(Locale.US, "%.2f V", b.voltageV);
        String current = Double.isNaN(b.currentNowMa) ? "N/A"
                : String.format(Locale.US, "%.0f mAh", b.chargeCounterMah);

        batterySection.summary.setText((b.level >= 0 ? b.level + "%" : "N/A")
                + "  •  " + b.status + "  •  Health " + health);
        batteryText.setText(
                "Estimated health : " + health + "\n"
                        + "Design capacity : " + design + "\n"
                        + "Design source   : " + b.designCapacitySource + "\n"
                        + (b.fullCapacityEstimated ? "Estimated full   : " : "Full capacity    : ") + full + "\n"
                        + "Capacity source : " + b.fullCapacitySource + "\n"
                        + "Temperature     : " + temp + "\n"
                        + "Voltage         : " + voltage + "\n"
                        + "Current charge  : " + current
        );

        systemSection.summary.setText("RAM " + Math.round(ram.usedPercent) + "%  •  Storage "
                + Math.round(storage.usedPercent) + "%");
        systemText.setText(
                "RAM      : " + Math.round(ram.usedPercent) + "% used  •  "
                        + DeviceMetrics.fmt2(ram.freeGb) + " GB free / "
                        + DeviceMetrics.fmt2(ram.totalGb) + " GB\n"
                        + "Storage  : " + Math.round(storage.usedPercent) + "% used  •  "
                        + DeviceMetrics.fmt2(storage.freeGb) + " GB free / "
                        + DeviceMetrics.fmt2(storage.totalGb) + " GB"
        );

        String rssi = wifi.rssi == Integer.MIN_VALUE ? "N/A" : wifi.rssi + " dBm";
        String speed = wifi.linkSpeedMbps < 0 ? "N/A" : wifi.linkSpeedMbps + " Mbps";
        String freq = wifi.frequencyMhz < 0 ? "N/A" : wifi.frequencyMhz + " MHz";
        String nearbyPermission = permissionState(Manifest.permission.NEARBY_WIFI_DEVICES, 33);
        String locationPermission = permissionState(Manifest.permission.ACCESS_FINE_LOCATION, 23);
        String locationService = isLocationEnabled() ? "ON" : "OFF";
        boolean ignoringBatteryOpt = isIgnoringBatteryOptimizations();

        networkSection.summary.setText((wifi.connected ? "Wi-Fi Connected" : "Not Connected")
                + "  •  " + rssi + "  •  " + wifi.ip);
        networkText.setText(
                "Wi-Fi          : " + (wifi.connected ? "Connected" : "Not Connected") + "\n"
                        + "SSID           : " + wifi.ssid + "\n"
                        + "Signal         : " + rssi + "\n"
                        + "Link speed     : " + speed + "\n"
                        + "Frequency      : " + freq + "\n"
                        + "IP             : " + wifi.ip + "\n"
                        + "Detection      : " + wifi.detectionSource + "\n"
                        + "Details source : " + wifi.detailsSource + "\n"
                        + "Nearby Wi-Fi   : " + nearbyPermission + "\n"
                        + "Fine location  : " + locationPermission + "\n"
                        + "Location svc   : " + locationService + "\n"
                        + "Battery Opt    : " + (ignoringBatteryOpt ? "Unrestricted (Safe)" : "Optimized (Risk of sleep)")
        );

        deviceSection.summary.setText(device.manufacturer + " " + device.model
                + "  •  Android " + device.androidVersion);
        deviceText.setText(
                "Manufacturer : " + device.manufacturer + "\n"
                        + "Model        : " + device.model + "\n"
                        + "Profile      : " + device.profile + "\n"
                        + "Android      : " + device.androidVersion + " (SDK " + device.sdk + ")\n"
                        + "Device uptime: " + CheckmkOutput.formatDuration(device.uptimeMs)
        );

        settingsSection.summary.setText(AgentConfig.getHostname(this) + "  •  TCP "
                + AgentConfig.getPort(this) + "  •  Push "
                + (AgentConfig.isPushConfigured(this) ? "ON" : "OFF"));

        diagnosticsSection.summary.setText("Pulls " + stats.accepted + "  •  Push OK "
                + stats.pushSuccesses + "  •  Push fail " + stats.pushFailures);
        diagnosticsText.setText(
                "Accepted pulls : " + stats.accepted + "\n"
                        + "Rejected pulls : " + stats.rejected + "\n"
                        + "Last rejected  : " + stats.lastRejected + "\n"
                        + "Push attempts  : " + stats.pushAttempts + "\n"
                        + "Push successes : " + stats.pushSuccesses + "\n"
                        + "Push failures  : " + stats.pushFailures + "\n"
                        + "Last push code : " + stats.lastPushCode + "\n"
                        + "Last push msg  : " + stats.lastPushMessage + "\n"
                        + "Foreground svc : " + (stats.running ? "running" : "stopped") + "\n"
                        + "AccuMeter smpl : " + b.estimateSamples + "\n"
                        + "Package        : com.bcp.checkmkagent"
        );
    }

    private TextView ensureTransportBody() {
        if (transportSection.content.getChildCount() >= 2
                && transportSection.content.getChildAt(1) instanceof TextView) {
            return (TextView) transportSection.content.getChildAt(1);
        }
        TextView body = bodyText();
        body.setPadding(0, dp(10), 0, 0);
        transportSection.content.addView(body, wrap());
        return body;
    }

    private void testPushNow() {
        if (!saveConfigOnly()) return;
        if (!AgentConfig.isPushConfigured(this)) {
            Toast.makeText(this, "Isi Push Receiver URL dan aktifkan PUSH backup terlebih dahulu", Toast.LENGTH_LONG).show();
            return;
        }
        Toast.makeText(this, "Mengirim test push...", Toast.LENGTH_SHORT).show();
        new Thread(() -> {
            PushClient.Result result = PushClient.pushNow(getApplicationContext());
            runOnUiThread(() -> {
                Toast.makeText(this, result.ok
                        ? "Push OK (HTTP " + result.code + ")"
                        : "Push gagal: " + result.message, Toast.LENGTH_LONG).show();
                updateDashboard();
            });
        }, "cmkagent-test-push").start();
    }

    private void showAgentOutput() {
        if (!saveConfigOnly()) return;
        TextView text = new TextView(this);
        text.setText(CheckmkOutput.build(this));
        text.setTextIsSelectable(true);
        text.setTypeface(Typeface.MONOSPACE);
        text.setTextColor(C_TEXT);
        text.setTextSize(12);
        text.setPadding(dp(16), dp(16), dp(16), dp(16));
        text.setBackgroundColor(C_BG);

        ScrollView scroller = new ScrollView(this);
        scroller.setBackgroundColor(C_BG);
        scroller.addView(text);

        AlertDialog dialog = new AlertDialog.Builder(this)
                .setTitle("Checkmk agent output")
                .setView(scroller)
                .setPositiveButton("CLOSE", null)
                .create();
        dialog.setOnShowListener(d -> {
            if (dialog.getButton(AlertDialog.BUTTON_POSITIVE) != null) {
                dialog.getButton(AlertDialog.BUTTON_POSITIVE).setTextColor(C_GREEN);
            }
        });
        dialog.show();
        updateDashboard();
    }

    private void requestRuntimePermissionsIfNeeded() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return;
        List<String> needed = new ArrayList<>();
        if (Build.VERSION.SDK_INT >= 33
                && checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)
                != PackageManager.PERMISSION_GRANTED) {
            needed.add(Manifest.permission.POST_NOTIFICATIONS);
        }
        if (Build.VERSION.SDK_INT >= 33
                && checkSelfPermission(Manifest.permission.NEARBY_WIFI_DEVICES)
                != PackageManager.PERMISSION_GRANTED) {
            needed.add(Manifest.permission.NEARBY_WIFI_DEVICES);
        }
        if (checkSelfPermission(Manifest.permission.ACCESS_FINE_LOCATION)
                != PackageManager.PERMISSION_GRANTED) {
            needed.add(Manifest.permission.ACCESS_FINE_LOCATION);
        }
        if (!needed.isEmpty()) requestPermissions(needed.toArray(new String[0]), 1001);
    }

    private String permissionState(String permission, int minSdk) {
        if (Build.VERSION.SDK_INT < minSdk) return "N/A";
        return checkSelfPermission(permission) == PackageManager.PERMISSION_GRANTED
                ? "Granted" : "Denied";
    }

    private boolean isLocationEnabled() {
        try {
            LocationManager lm = (LocationManager) getSystemService(LOCATION_SERVICE);
            if (lm == null) return false;
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) return lm.isLocationEnabled();
            return lm.isProviderEnabled(LocationManager.GPS_PROVIDER)
                    || lm.isProviderEnabled(LocationManager.NETWORK_PROVIDER);
        } catch (Exception ignored) {
            return false;
        }
    }

    private boolean isIgnoringBatteryOptimizations() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            PowerManager pm = (PowerManager) getSystemService(POWER_SERVICE);
            return pm != null && pm.isIgnoringBatteryOptimizations(getPackageName());
        }
        return true;
    }

    private void requestIgnoreBatteryOptimizations() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            try {
                Intent intent = new Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS);
                intent.setData(Uri.parse("package:" + getPackageName()));
                startActivity(intent);
            } catch (Exception e) {
                openAppSettings();
            }
        }
    }

    private void openAppSettings() {
        Intent intent = new Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                Uri.parse("package:" + getPackageName()));
        startActivity(intent);
    }

    private EditText input(LinearLayout parent, String label, int type, String hint) {
        TextView l = new TextView(this);
        l.setText(label);
        l.setTextColor(C_MUTED);
        l.setTextSize(12);
        l.setTypeface(Typeface.DEFAULT_BOLD);
        l.setPadding(0, dp(6), 0, dp(3));
        parent.addView(l, wrap());

        EditText e = new EditText(this);
        e.setSingleLine(true);
        e.setInputType(type);
        e.setTextColor(C_TEXT);
        e.setHintTextColor(Color.rgb(102, 119, 133));
        e.setHint(hint);
        e.setTextSize(15);
        e.setPadding(dp(12), 0, dp(12), 0);
        e.setBackground(rounded(C_CARD_ALT, 10, C_LINE, 1));
        parent.addView(e, matchHeightMargin(48, 0, 0, 0, 8));
        return e;
    }

    private TextView bodyText() {
        TextView v = new TextView(this);
        v.setTextColor(C_TEXT);
        v.setTextSize(14);
        v.setLineSpacing(0, 1.15f);
        return v;
    }

    private TextView badge(String text, int color) {
        TextView v = new TextView(this);
        v.setText(text);
        v.setTextSize(12);
        v.setTypeface(Typeface.DEFAULT_BOLD);
        v.setPadding(dp(10), dp(5), dp(10), dp(5));
        styleBadge(v, color);
        return v;
    }

    private void styleBadge(TextView v, int color) {
        v.setTextColor(color);
        v.setBackground(rounded(withAlpha(color, 35), 20, withAlpha(color, 110), 1));
    }

    private Button actionButton(String text, int bg, int fg) {
        Button b = new Button(this);
        b.setText(text);
        b.setTextColor(fg);
        b.setTextSize(12);
        b.setTypeface(Typeface.DEFAULT_BOLD);
        b.setAllCaps(false);
        b.setGravity(Gravity.CENTER);
        b.setMinHeight(0);
        b.setMinimumHeight(0);
        b.setBackground(rounded(bg, 11, C_LINE, 1));
        return b;
    }

    private GradientDrawable rounded(int color, int radiusDp, int strokeColor, int strokeDp) {
        GradientDrawable d = new GradientDrawable();
        d.setColor(color);
        d.setCornerRadius(dp(radiusDp));
        if (strokeDp > 0) d.setStroke(dp(strokeDp), strokeColor);
        return d;
    }

    private int withAlpha(int color, int alpha) {
        return Color.argb(alpha, Color.red(color), Color.green(color), Color.blue(color));
    }

    private View space(int heightDp) {
        View v = new View(this);
        v.setLayoutParams(new LinearLayout.LayoutParams(1, dp(heightDp)));
        return v;
    }

    private LinearLayout.LayoutParams wrap() {
        return new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.WRAP_CONTENT,
                ViewGroup.LayoutParams.WRAP_CONTENT);
    }

    private LinearLayout.LayoutParams matchWrap() {
        return new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.WRAP_CONTENT);
    }

    private LinearLayout.LayoutParams matchWrapMargin(int left, int top, int right, int bottom) {
        LinearLayout.LayoutParams p = matchWrap();
        p.setMargins(dp(left), dp(top), dp(right), dp(bottom));
        return p;
    }

    private LinearLayout.LayoutParams matchHeightMargin(
            int height, int left, int top, int right, int bottom) {
        LinearLayout.LayoutParams p = new LinearLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT, dp(height));
        p.setMargins(dp(left), dp(top), dp(right), dp(bottom));
        return p;
    }

    private LinearLayout.LayoutParams weightButton() {
        return new LinearLayout.LayoutParams(0, dp(48), 1f);
    }

    private int dp(int value) {
        return Math.round(value * getResources().getDisplayMetrics().density);
    }

    private String formatDate(long millis) {
        return new SimpleDateFormat("yyyy-MM-dd HH:mm:ss", Locale.getDefault())
                .format(new Date(millis));
    }

    private static final class Section {
        LinearLayout card;
        LinearLayout content;
        TextView arrow;
        TextView summary;
        boolean expanded;
    }
}
