// SPDX-License-Identifier: GPL-3.0-or-later
// Presents grouped preferences and product links while preserving existing values and navigation.
package io.github.anisharyal09.anice.app

import android.content.Context
import android.os.Build
import android.widget.Toast
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.Image
import androidx.compose.foundation.clickable
import androidx.compose.foundation.relocation.BringIntoViewRequester
import androidx.compose.foundation.relocation.bringIntoViewRequester
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import io.github.anisharyal09.anice.R
import io.github.anisharyal09.anice.features.deviceidentity.DeviceIdentityViewModel
import io.github.anisharyal09.anice.infrastructure.pairing.PeerTrustRecord
import io.github.anisharyal09.anice.ui.AutomaticConnectionToggle
import io.github.anisharyal09.anice.ui.theme.Appearance
import io.github.anisharyal09.anice.ui.theme.appearancePreference
import io.github.anisharyal09.anice.ui.theme.saveAppearance
import io.github.anisharyal09.anice.ui.theme.AniCeWordmark
import io.github.anisharyal09.anice.ui.theme.fontScalePreference
import io.github.anisharyal09.anice.ui.theme.saveFontScale
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics

private val LocalSettingsCategory = staticCompositionLocalOf { SettingsCategory.All }
private val LocalSettingsTarget = staticCompositionLocalOf<String?> { null }

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(
    identity: DeviceIdentityViewModel,
    snackbars: SnackbarHostState,
    navigation: AppNavigation,
    context: Context,
    peers: List<PeerTrustRecord> = emptyList(),
) {
    var showingIdentity by rememberSaveable { mutableStateOf(false) }
    if (showingIdentity) LocalIdentitySheet(identity) { showingIdentity = false }
    val app = context.applicationContext as io.github.anisharyal09.anice.AniCeApplication
    val lifecycle = androidx.lifecycle.compose.LocalLifecycleOwner.current.lifecycle
    var notificationPermissions by remember(context) {
        mutableStateOf(io.github.anisharyal09.anice.features.notifications.notificationPermissionSnapshot(context))
                    }
    var findPhoneNotificationsAllowed by remember(context) { mutableStateOf(app.findDeviceNotification.permitted()) }
    fun refreshPermissions() {
        app.sms.refreshPermissions()
        app.dndSync.refreshAccess()
        notificationPermissions = io.github.anisharyal09.anice.features.notifications.notificationPermissionSnapshot(context)
        findPhoneNotificationsAllowed = app.findDeviceNotification.permitted()
    }
    DisposableEffect(lifecycle, app.sms, app.dndSync, context) {
        val observer = androidx.lifecycle.LifecycleEventObserver { _, event ->
            if (event == androidx.lifecycle.Lifecycle.Event.ON_RESUME) refreshPermissions()
        }
        lifecycle.addObserver(observer)
        refreshPermissions()
        onDispose { lifecycle.removeObserver(observer) }
    }
    if (navigation.destination == AppDestination.About || navigation.settingsRoute == SettingsRoute.About) {
        AboutScreen(context)
    } else if (navigation.destination == AppDestination.Settings &&
        navigation.settingsRoute == SettingsRoute.NotificationApps) {
        io.github.anisharyal09.anice.features.notifications.NotificationAppSelection(app.notificationMirror)
    } else {
        val lan = app.lanSessionController
        var selectedCategory by rememberSaveable { mutableStateOf(SettingsCategory.All) }
        val activeCategory = selectedCategory.takeIf { it in SettingsCategory.visibleEntries } ?: SettingsCategory.All
        val showGrantedPermissions = activeCategory == SettingsCategory.Permissions
        val hasMissingPermissions = !app.sms.granted || !notificationPermissions.allAllowed ||
            !app.dndSync.granted || !findPhoneNotificationsAllowed
        val scrollState = rememberScrollState()
        LaunchedEffect(selectedCategory) {
            if (selectedCategory !in SettingsCategory.visibleEntries) selectedCategory = SettingsCategory.All
            scrollState.scrollTo(0)
        }
        LaunchedEffect(navigation.settingsSection) {
            navigation.settingsSection?.let { selectedCategory = SettingsCategory.forSection(it) }
        }
        val lanPrefs = remember { context.getSharedPreferences("lan_preferences", Context.MODE_PRIVATE) }
        var timeoutMinutes by remember { mutableIntStateOf(lanPrefs.getInt("lan_background_timeout_minutes", 0)) }
        var timeoutExpanded by remember { mutableStateOf(false) }
        var appearanceExpanded by remember { mutableStateOf(false) }
        val timeoutOptions = listOf(1 to "1 min", 3 to "3 min", 5 to "5 min", 10 to "10 min", 0 to "Never")
        val appearance = appearancePreference()

        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.TopCenter) {
            Column(
                Modifier.widthIn(max = 680.dp).fillMaxWidth().padding(horizontal = 16.dp, vertical = 16.dp),
                verticalArrangement = Arrangement.spacedBy(12.dp)
            ) {
                Text("Settings", style = MaterialTheme.typography.titleMedium)
                FlowRow(
                    Modifier.fillMaxWidth().selectableGroup(),
                    horizontalArrangement = Arrangement.spacedBy(4.dp),
                    verticalArrangement = Arrangement.spacedBy(4.dp),
                ) {
                    SettingsCategory.visibleEntries.forEach { category ->
                        FilterChip(
                            selected = activeCategory == category,
                            onClick = { selectedCategory = category },
                            label = { Text(category.label) },
                            modifier = Modifier.defaultMinSize(minHeight = 32.dp),
                        )
                        }
                }

                CompositionLocalProvider(LocalSettingsCategory provides activeCategory,
                    LocalSettingsTarget provides navigation.settingsSection) {
                Column(
                    Modifier.weight(1f).fillMaxWidth().verticalScroll(scrollState)
                        .padding(top = 4.dp),
                    verticalArrangement = Arrangement.spacedBy(18.dp)
                ) {
                    SettingsCategoryHeading(SettingsCategory.General)
                    PreferenceSection("Appearance") {
                        Box {
                            Row(
                                Modifier.fillMaxWidth().heightIn(min = 48.dp)
                                    .clickable(role = Role.Button, onClickLabel = "Choose appearance") { appearanceExpanded = true },
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Text("Appearance", Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
                                Text(appearance.name, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                Icon(painterResource(R.drawable.ic_chevron_forward), contentDescription = null,
                                    modifier = Modifier.padding(start = 8.dp).size(16.dp).graphicsLayer(rotationZ = 90f),
                                    tint = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                            DropdownMenu(expanded = appearanceExpanded, onDismissRequest = { appearanceExpanded = false }) {
                                Appearance.entries.forEach { mode ->
                                    DropdownMenuItem(
                                        text = { Text(mode.name) },
                                        trailingIcon = if (appearance == mode) ({ Text("✓") }) else null,
                                        onClick = { appearanceExpanded = false; saveAppearance(context, mode) }
                                    )
                                }
                            }
                        }
                        HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
                        val savedScale = fontScalePreference()
                        var sliderPosition by remember(savedScale) { mutableFloatStateOf(savedScale) }
                        Row(
                            Modifier.fillMaxWidth().heightIn(min = 48.dp),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Text("Text size", Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
                            Text(
                                "${kotlin.math.round(sliderPosition * 100).toInt()}%",
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                            Spacer(Modifier.width(8.dp))
                            Slider(
                                value = sliderPosition,
                                onValueChange = { sliderPosition = kotlin.math.round(it * 20f) / 20f },
                                onValueChangeFinished = { saveFontScale(context, sliderPosition) },
                                valueRange = 0.80f..1.20f,
                                thumb = { Box(Modifier.size(12.dp).background(MaterialTheme.colorScheme.onSurface, androidx.compose.foundation.shape.CircleShape)) },
                                track = { slider -> SliderDefaults.Track(slider, modifier = Modifier.height(3.dp), thumbTrackGapSize = 2.dp) },
                                modifier = Modifier.width(130.dp)
                            )
                            if (kotlin.math.abs(sliderPosition - 1.0f) > 0.02f) {
                                Spacer(Modifier.width(4.dp))
                                TextButton(
                                    onClick = {
                                        sliderPosition = 1.0f
                                        saveFontScale(context, 1.0f)
                                    },
                                    contentPadding = PaddingValues(horizontal = 4.dp, vertical = 0.dp),
                                    modifier = Modifier.heightIn(min = 32.dp)
                                ) {
                                    Text("Reset", style = MaterialTheme.typography.labelSmall)
                                }
                            }
                        }
                    }

                    PreferenceSection("Updates") {
                        io.github.anisharyal09.anice.update.UpdateSettings(app.updates)
                    }

                    PreferenceSection("Connection") {
                        AutomaticConnectionToggle(
                            checked = lan.automatic,
                            enabled = true,
                            onCheckedChange = lan::setAutomaticEnabled,
                            label = "Use local network automatically",
                            description = "Enable on both devices to use Wi-Fi.",
                            compact = true,
                        )
                        HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
                        Box {
                            Row(
                                Modifier.fillMaxWidth().heightIn(min = 48.dp)
                                    .clickable(role = Role.Button, onClickLabel = "Choose background timeout") { timeoutExpanded = true },
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Column(
                                    Modifier.weight(1f).padding(vertical = 6.dp),
                                    verticalArrangement = Arrangement.spacedBy(4.dp)
                                ) {
                                    Text("Idle LAN in background", style = MaterialTheme.typography.bodyMedium)
                                    Text("Closes idle LAN after Home or lock. Active work stays connected.",
                                        style = MaterialTheme.typography.bodySmall,
                                        color = MaterialTheme.colorScheme.onSurfaceVariant)
                                    lan.backgroundRetentionReason?.let {
                                        Text(it, style = MaterialTheme.typography.bodySmall,
                                            color = MaterialTheme.colorScheme.onSurfaceVariant)
                                    }
                                }
                                Spacer(Modifier.width(8.dp))
                                Text(timeoutOptions.firstOrNull { it.first == timeoutMinutes }?.second
                                        ?: if (timeoutMinutes > 0) "$timeoutMinutes min" else "Never",
                                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                Icon(painterResource(R.drawable.ic_chevron_forward), contentDescription = null,
                                    modifier = Modifier.padding(start = 8.dp).size(16.dp).graphicsLayer(rotationZ = 90f),
                                    tint = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                            DropdownMenu(expanded = timeoutExpanded, onDismissRequest = { timeoutExpanded = false }) {
                                timeoutOptions.forEach { (minutes, label) ->
                                    DropdownMenuItem(
                                        text = { Text(label) },
                                        trailingIcon = if (timeoutMinutes == minutes) ({ Text("✓") }) else null,
                                        onClick = {
                                            timeoutExpanded = false
                                            timeoutMinutes = minutes
                                            lan.setBackgroundTimeoutMinutes(minutes)
                                        }
                                    )
                                }
                            }
                        }
                    }

                    PreferenceSection("This device") {
                        Row(
                            Modifier.fillMaxWidth().heightIn(min = 52.dp)
                                .clickable(role = Role.Button, onClickLabel = "Open identity and security") {
                                    showingIdentity = true
                                }.padding(vertical = 6.dp),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                                Text(identity.state.snapshot?.identity?.deviceName ?: "This device",
                                    style = MaterialTheme.typography.bodyMedium)
                                Text("Identity and security", style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                            Icon(painterResource(R.drawable.ic_chevron_forward), contentDescription = null,
                                modifier = Modifier.size(18.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                    if (showGrantedPermissions || hasMissingPermissions) {
                        SettingsCategoryHeading(SettingsCategory.Permissions)
                        PreferenceSection("Permissions") {
                            for ((name, allowed, purpose) in listOf(
                                Triple("Receive SMS", app.sms.permissionsState.receive, "Relay incoming SMS to Mac."),
                                Triple("Read SMS", app.sms.permissionsState.read, "Read conversations and search on your phone."),
                                Triple("Send SMS", app.sms.permissionsState.send, "Send replies composed on Mac."),
                            )) {
                                io.github.anisharyal09.anice.ui.PermissionStatusRow(
                                    name, allowed, purpose, showGrantedPermissions)
                            }
                            if (!app.sms.granted) {
                                TextButton(onClick = { navigation.openFeature(AppFeature.Sms) },
                                    contentPadding = PaddingValues(horizontal = 8.dp, vertical = 2.dp),
                                    modifier = Modifier.defaultMinSize(minHeight = 32.dp)) { Text("Open Messages setup") }
                            }
                            io.github.anisharyal09.anice.features.sms.SmsSimPermissionSettings(
                                notificationPermissions.phoneState, showGrantedPermissions,
                                onPermissionsChanged = ::refreshPermissions)
                            io.github.anisharyal09.anice.features.finddevice.FindDevicePermissionSettings(
                                findPhoneNotificationsAllowed, showGrantedPermissions,
                                onPermissionsChanged = ::refreshPermissions)
                            io.github.anisharyal09.anice.features.notifications.NotificationSettings(
                                app.notificationMirror, permissionsOnly = true,
                                showGranted = showGrantedPermissions, onPermissionsChanged = ::refreshPermissions)
                            io.github.anisharyal09.anice.features.dndsync.DndSyncSettings(
                                app.dndSync, permissionsOnly = true, showGranted = showGrantedPermissions)
                        }
                    }
                    SettingsCategoryHeading(SettingsCategory.Features)
                    PreferenceSection("Do Not Disturb") {
                        io.github.anisharyal09.anice.features.dndsync.DndSyncSettings(app.dndSync)
                    }

                    PreferenceSection("Clipboard") {
                        io.github.anisharyal09.anice.features.clipboard.ClipboardSettings(app.clipboard, peers, grouped = true)
                    }

                    if (!app.sms.granted) {
                        PreferenceSection("Messages") {
                            io.github.anisharyal09.anice.features.sms.SmsSettings(app.sms)
                        }
                    }

                    PreferenceSection("Notification sync") {
                        io.github.anisharyal09.anice.features.notifications.NotificationSettings(app.notificationMirror)
                        HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
                        val selectedCount = app.notificationMirror.preferences.selectedPackages().size
                        Row(Modifier.fillMaxWidth().heightIn(min = 52.dp)
                            .clickable(role = Role.Button, onClickLabel = "Select apps") { navigation.settingsRoute = SettingsRoute.NotificationApps }
                            .padding(vertical = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                                Text("Select apps", style = MaterialTheme.typography.bodyMedium)
                                Text(when (selectedCount) { 0 -> "No apps selected"; 1 -> "1 app selected"; else -> "$selectedCount apps selected" },
                                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                            Icon(painterResource(R.drawable.ic_chevron_forward), contentDescription = null,
                                modifier = Modifier.size(18.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }

                    PreferenceSection("File transfer") {
                        io.github.anisharyal09.anice.features.transfer.TransferAutoReceiveSettings(
                            preferences = app.transfer.autoReceivePreferences,
                            peers = peers,
                            compact = true,
                            modifier = Modifier.padding(vertical = 6.dp),
                        )
                    }

                }
                }
            }
        }
    }
}

@Composable
private fun PreferenceSection(
    title: String,
    modifier: Modifier = Modifier,
    highlighted: Boolean = false,
    content: @Composable ColumnScope.() -> Unit,
) {
    val category = LocalSettingsCategory.current
    if (category != SettingsCategory.All && category != SettingsCategory.forSection(title)) return
    val requester = remember { BringIntoViewRequester() }
    val target = LocalSettingsTarget.current
    LaunchedEffect(target, category) {
        if (target == title) {
            withFrameNanos { }
            requester.bringIntoView()
        }
    }
    val shape = RoundedCornerShape(8.dp)
    Column(modifier.bringIntoViewRequester(requester), verticalArrangement = Arrangement.spacedBy(7.dp)) {
        if (title != "Permissions") {
            Text(title, Modifier.padding(horizontal = 2.dp), style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        Surface(
            modifier = Modifier.fillMaxWidth().then(
                if (highlighted) Modifier.border(1.dp, MaterialTheme.colorScheme.primary, shape) else Modifier
            ),
            shape = shape,
            color = if (highlighted) MaterialTheme.colorScheme.primaryContainer else MaterialTheme.colorScheme.surfaceContainer
        ) {
            Column(Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 4.dp), content = content)
        }
    }
}

@Composable
private fun SettingsCategoryHeading(category: SettingsCategory) {
    val selected = LocalSettingsCategory.current
    if (selected == SettingsCategory.All || selected == category) {
        Text(category.label, Modifier.semantics { heading() },
            style = MaterialTheme.typography.titleSmall)
    }
}

@Composable
internal fun AboutScreen(context: Context) {
    val uriHandler = LocalUriHandler.current
    val installedVersion = remember(context) {
        context.packageManager.getPackageInfo(context.packageName, 0).versionName.orEmpty()
    }
    val version = installedVersion.takeIf { it.isNotEmpty() }?.let { "Version $it" }.orEmpty()
    val reportUrl = remember(installedVersion) {
        IssueReport.url(installedVersion.ifEmpty { "Unknown" }, "Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})")
    }
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.TopCenter) {
        Column(
            Modifier.widthIn(max = 660.dp).fillMaxWidth().verticalScroll(rememberScrollState())
                .padding(horizontal = 16.dp, vertical = 20.dp)
        ) {
            Text("About", style = MaterialTheme.typography.titleMedium)
            Text("Android + Mac, like never before.",
                Modifier.padding(top = 6.dp, bottom = 16.dp),
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            BoxWithConstraints(Modifier.fillMaxWidth()) {
                val compact = maxWidth < 300.dp || LocalDensity.current.fontScale >= 1.4f
                if (compact) {
                    Column(Modifier.fillMaxWidth().padding(vertical = 10.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                            Image(painterResource(R.drawable.ic_brand_mark), contentDescription = null,
                                modifier = Modifier.size(20.dp))
                            AniCeWordmark(style = MaterialTheme.typography.titleMedium)
                        }
                        Column(Modifier.padding(start = 32.dp), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                            Text("macOS + Android", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            if (version.isNotEmpty()) Text(version, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                } else {
                    Row(Modifier.fillMaxWidth().heightIn(min = 56.dp), verticalAlignment = Alignment.CenterVertically) {
                        Image(painterResource(R.drawable.ic_brand_mark), contentDescription = null,
                            modifier = Modifier.size(20.dp))
                        Spacer(Modifier.width(12.dp))
                        AniCeWordmark(style = MaterialTheme.typography.titleMedium)
                        Spacer(Modifier.weight(1f))
                        Column(horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(2.dp)) {
                            Text("macOS + Android", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            if (version.isNotEmpty()) Text(version, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                }
            }
            HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
            AboutDetailRow("Source code", "GitHub", "https://github.com/anisharyal09/aniCe", uriHandler::openUri)
            AboutDetailRow("License", "GPL-3.0-or-later", "https://github.com/anisharyal09/aniCe/blob/main/LICENSE", uriHandler::openUri)
            AboutFeedbackRow(
                onReport = { uriHandler.openUri(reportUrl) },
                onEmail = {
                    try {
                        uriHandler.openUri(IssueReport.emailUrl)
                    } catch (_: IllegalArgumentException) {
                        Toast.makeText(context, "No email app is available. Email ${IssueReport.emailAddress}.", Toast.LENGTH_LONG).show()
                    }
                },
            )
            BoxWithConstraints(Modifier.fillMaxWidth().padding(vertical = 4.dp)) {
                val compact = maxWidth < 320.dp || LocalDensity.current.fontScale >= 1.4f
                if (compact) {
                    Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.End,
                        verticalArrangement = Arrangement.spacedBy(2.dp)) {
                        Text("Reach out", Modifier.fillMaxWidth(), style = MaterialTheme.typography.bodyMedium)
                        AboutContactLinks(uriHandler::openUri)
                    }
                } else {
                    Row(Modifier.fillMaxWidth().heightIn(min = 48.dp), verticalAlignment = Alignment.CenterVertically) {
                        Text("Reach out", Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
                        AboutContactLinks(uriHandler::openUri)
                    }
                }
            }
            HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
            Column(Modifier.fillMaxWidth().padding(top = 16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text("No account needed to connect your devices. No telemetry. Updates and issue reports use GitHub.",
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally) {
                    Row(
                        modifier = Modifier.heightIn(min = 48.dp)
                            .clip(RoundedCornerShape(7.dp))
                            .clickable(role = Role.Button, onClickLabel = "Support aniCe") {
                                uriHandler.openUri("https://anisharyal09.com.np/support?from=anice")
                            }
                            .padding(horizontal = 8.dp, vertical = 4.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                    ) {
                        Icon(painterResource(R.drawable.ic_heart), contentDescription = null,
                            tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(13.dp))
                        AniCeWordmark(
                            style = MaterialTheme.typography.labelMedium.copy(color = MaterialTheme.colorScheme.onSurfaceVariant),
                            prefix = "Support ", suffix = " :)", textAlign = TextAlign.Center,
                        )
                    }
                    Box(
                        modifier = Modifier.heightIn(min = 48.dp)
                            .clip(RoundedCornerShape(7.dp))
                            .clickable(role = Role.Button, onClickLabel = "Star aniCe on GitHub") {
                                uriHandler.openUri("https://github.com/anisharyal09/aniCe")
                            }
                            .padding(horizontal = 8.dp, vertical = 4.dp),
                        contentAlignment = Alignment.Center,
                    ) {
                        AniCeWordmark(
                            style = MaterialTheme.typography.bodySmall.copy(color = MaterialTheme.colorScheme.onSurfaceVariant),
                            prefix = "☆ Star ", suffix = " on GitHub", textAlign = TextAlign.Center,
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun AboutFeedbackRow(onReport: () -> Unit, onEmail: () -> Unit) {
    BoxWithConstraints(Modifier.fillMaxWidth()) {
        val density = LocalDensity.current
        val measurer = rememberTextMeasurer()
        val labelWidth = with(density) {
            measurer.measure("Report an issue", MaterialTheme.typography.bodyMedium).size.width.toDp()
        }
        val actionsWidth = with(density) {
            measurer.measure("GitHub form", MaterialTheme.typography.bodySmall).size.width.toDp() +
                measurer.measure("Email", MaterialTheme.typography.bodySmall).size.width.toDp()
        } + 84.dp // Two icons, label gaps, link padding and the independent action gap.
        val compact = maxWidth < labelWidth + actionsWidth + 12.dp
        val title: @Composable () -> Unit = {
            Box(
                Modifier.heightIn(min = 48.dp).clickable(role = Role.Button, onClickLabel = "Report an issue", onClick = onReport),
                contentAlignment = Alignment.CenterStart,
            ) { Text("Report an issue", style = MaterialTheme.typography.bodyMedium) }
        }
        val actions: @Composable () -> Unit = {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                AboutFeedbackAction("GitHub form", R.drawable.ic_external_link, onReport, Modifier.weight(1f, fill = false))
                AboutFeedbackAction("Email", R.drawable.ic_email, onEmail)
            }
        }
        if (compact) {
            Column(Modifier.fillMaxWidth()) {
                title()
                Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.CenterEnd) { actions() }
            }
        } else {
            Row(Modifier.fillMaxWidth().heightIn(min = 54.dp), verticalAlignment = Alignment.CenterVertically) {
                title()
                Spacer(Modifier.weight(1f))
                actions()
            }
        }
    }
    HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
}

@Composable
private fun AboutFeedbackAction(label: String, icon: Int, onClick: () -> Unit, modifier: Modifier = Modifier) {
    Row(
        modifier.heightIn(min = 48.dp).clip(RoundedCornerShape(7.dp))
            .clickable(role = Role.Button, onClickLabel = label, onClick = onClick)
            .padding(horizontal = 8.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        Icon(painterResource(icon), contentDescription = null, modifier = Modifier.size(16.dp),
            tint = MaterialTheme.colorScheme.onSurfaceVariant)
        Text(label, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant,
            softWrap = label != "Email")
    }
}

@Composable
private fun AboutDetailRow(label: String, detail: String, url: String, openUri: (String) -> Unit,
    modifier: Modifier = Modifier, showDivider: Boolean = true) {
    Column(modifier) {
        BoxWithConstraints(Modifier.fillMaxWidth()) {
            val compact = maxWidth < 240.dp || LocalDensity.current.fontScale >= 1.6f
            val rowModifier = Modifier.fillMaxWidth().heightIn(min = 54.dp)
                .clickable(role = Role.Button, onClickLabel = "$label, $detail") { openUri(url) }
            if (compact) {
                Column(rowModifier.padding(vertical = 8.dp), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                    Text(label, style = MaterialTheme.typography.bodyMedium)
                    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                        Text(detail, Modifier.weight(1f), style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant)
                        Icon(painterResource(R.drawable.ic_external_link), contentDescription = null,
                            modifier = Modifier.padding(start = 8.dp).size(16.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            } else {
                Row(rowModifier, verticalAlignment = Alignment.CenterVertically) {
                    Text(label, Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
                    Text(detail, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    Icon(painterResource(R.drawable.ic_external_link), contentDescription = null,
                        modifier = Modifier.padding(start = 8.dp).size(16.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        }
        if (showDivider) HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
    }
}


@Composable
private fun AboutContactLinks(openUri: (String) -> Unit) {
    Row(Modifier.width(IntrinsicSize.Max), verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(4.dp)) {
        Row(
            Modifier.weight(1f, fill = false).heightIn(min = 48.dp)
                .clickable(role = Role.Button, onClickLabel = "GitHub profile, @anisharyal09") {
                    openUri("https://github.com/anisharyal09")
                },
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            Text("@anisharyal09", style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant)
            Icon(painterResource(R.drawable.ic_external_link), contentDescription = null,
                modifier = Modifier.size(16.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        AboutProfileLinks(openUri = openUri)
    }
}

@Composable
private fun AboutProfileLinks(modifier: Modifier = Modifier, openUri: (String) -> Unit) {
    Row(modifier, verticalAlignment = Alignment.CenterVertically) {
        IconButton(onClick = { openUri("https://x.com/anisharyal09") }, modifier = Modifier.size(48.dp)) {
            Icon(painterResource(R.drawable.ic_brand_x), contentDescription = "X profile",
                tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(16.dp).offset(x = 4.dp))
        }
        IconButton(onClick = { openUri("https://www.linkedin.com/in/anisharyal09/") },
            modifier = Modifier.size(48.dp)) {
            Icon(painterResource(R.drawable.ic_brand_linkedin), contentDescription = "LinkedIn profile",
                tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(16.dp).offset(x = (-4).dp))
        }
    }
}
