// SPDX-License-Identifier: GPL-3.0-or-later
// Presents grouped preferences and product links while preserving existing values and navigation.
package io.github.anisharyal09.anice.app

import android.content.Context
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.Image
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
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
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.layout.positionInRoot
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import io.github.anisharyal09.anice.R
import io.github.anisharyal09.anice.features.deviceidentity.DeviceIdentityViewModel
import io.github.anisharyal09.anice.infrastructure.pairing.PeerTrustRecord
import io.github.anisharyal09.anice.ui.AutomaticConnectionToggle
import io.github.anisharyal09.anice.ui.theme.Appearance
import io.github.anisharyal09.anice.ui.theme.appearancePreference
import io.github.anisharyal09.anice.ui.theme.saveAppearance
import io.github.anisharyal09.anice.ui.theme.fontScalePreference
import io.github.anisharyal09.anice.ui.theme.saveFontScale
import kotlinx.coroutines.launch
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collect

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
    if (navigation.destination == AppDestination.About || navigation.settingsRoute == SettingsRoute.About) {
        AboutScreen(context)
    } else if (navigation.destination == AppDestination.Settings &&
        navigation.settingsRoute == SettingsRoute.NotificationApps) {
        io.github.anisharyal09.anice.features.notifications.NotificationAppSelection(app.notificationMirror)
    } else {
        val lan = app.lanSessionController
        val sections = buildList {
            add("Appearance")
            add("Connection")
            add("Do Not Disturb")
            add("Clipboard")
            if (!app.sms.granted) add("Messages")
            add("Notification sync")
            add("File transfer")
            add("This device")
        }
        var selectedSection by rememberSaveable { mutableStateOf("Appearance") }
        val activeSection = selectedSection.takeIf { it in sections } ?: sections.first()
        LaunchedEffect(sections) {
            if (selectedSection !in sections) selectedSection = sections.first()
        }
        val scope = rememberCoroutineScope()
        val scrollState = rememberScrollState()
        val sectionOffsets = remember(sections) { mutableStateMapOf<String, Float>() }
        val sectionRequesters = remember(sections) { sections.associateWith { BringIntoViewRequester() } }
        var viewportTop by remember { mutableFloatStateOf(0f) }
        var movingToSection by remember { mutableStateOf(false) }
        var highlightedSection by remember { mutableStateOf<String?>(null) }
        var sectionJumpGeneration by remember { mutableIntStateOf(0) }
        val density = LocalDensity.current
        val selectedThreshold = with(density) { 32.dp.toPx() }
        val endThreshold = selectedThreshold.toInt()
        fun sectionAt(scrollPosition: Int, offsets: Map<String, Float>): String =
            if (scrollState.maxValue > endThreshold && scrollPosition >= scrollState.maxValue - endThreshold) sections.last()
            else sections.lastOrNull { (offsets[it] ?: Float.MAX_VALUE) <= scrollPosition + selectedThreshold }
                ?: sections.first()

        LaunchedEffect(scrollState, sections) {
            snapshotFlow { sectionAt(scrollState.value, sectionOffsets.toMap()) }
                .collect { current ->
                    if (!movingToSection) selectedSection = current
                }
        }

        fun sectionModifier(section: String): Modifier = Modifier
            .bringIntoViewRequester(sectionRequesters.getValue(section))
            .onGloballyPositioned { coordinates ->
                sectionOffsets[section] = coordinates.positionInRoot().y - viewportTop + scrollState.value
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
                Row(
                    Modifier.fillMaxWidth().horizontalScroll(rememberScrollState()).selectableGroup(),
                    horizontalArrangement = Arrangement.spacedBy(4.dp)
                ) {
                    sections.forEach { section ->
                        val selected = activeSection == section
                        val tabRequester = remember(section) { BringIntoViewRequester() }
                        val tabShape = RoundedCornerShape(8.dp)
                        LaunchedEffect(selected) {
                            if (selected) tabRequester.bringIntoView()
                        }
                        Box(
                            Modifier.bringIntoViewRequester(tabRequester)
                                .clip(tabShape)
                                .background(if (selected) MaterialTheme.colorScheme.primaryContainer.copy(alpha = 0.45f) else Color.Transparent, tabShape)
                                .then(if (selected) Modifier.border(1.dp, MaterialTheme.colorScheme.primary.copy(alpha = 0.25f), tabShape) else Modifier)
                                .selectable(selected = selected, role = Role.Tab) {
                                    val generation = ++sectionJumpGeneration
                                    selectedSection = section
                                    movingToSection = true
                                    highlightedSection = null
                                    scope.launch {
                                        try {
                                            sectionRequesters.getValue(section).bringIntoView()
                                            if (sectionJumpGeneration == generation) {
                                                selectedSection = section
                                                highlightedSection = section
                                            }
                                        } finally {
                                            if (sectionJumpGeneration == generation) {
                                                movingToSection = false
                                            }
                                        }
                                        if (sectionJumpGeneration == generation) {
                                            delay(700)
                                            if (sectionJumpGeneration == generation && highlightedSection == section)
                                                highlightedSection = null
                                        }
                                    }
                                }
                                .heightIn(min = 40.dp)
                                .padding(horizontal = 12.dp),
                            contentAlignment = Alignment.Center,
                        ) {
                            Text(section,
                                style = MaterialTheme.typography.labelLarge,
                                fontWeight = if (selected) FontWeight.Medium else FontWeight.Normal,
                                color = if (selected) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }
                }

                Column(
                    Modifier.weight(1f).fillMaxWidth().verticalScroll(scrollState)
                        .onGloballyPositioned { viewportTop = it.positionInRoot().y }
                        .padding(top = 4.dp),
                    verticalArrangement = Arrangement.spacedBy(18.dp)
                ) {
                    PreferenceSection("Appearance", sectionModifier("Appearance"), highlightedSection == "Appearance") {
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

                    PreferenceSection("Connection", sectionModifier("Connection"), highlightedSection == "Connection") {
                        AutomaticConnectionToggle(
                            checked = lan.automatic,
                            enabled = true,
                            onCheckedChange = lan::setAutomaticEnabled,
                            label = "Use local network automatically",
                            description = "Enable on both devices to use Wi-Fi."
                        )
                        HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
                        Box {
                            Row(
                                Modifier.fillMaxWidth().heightIn(min = 48.dp)
                                    .clickable(role = Role.Button, onClickLabel = "Choose background timeout") { timeoutExpanded = true },
                                verticalAlignment = Alignment.CenterVertically
                            ) {
                                Text("Background timeout", Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
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
                                            lanPrefs.edit().putInt("lan_background_timeout_minutes", minutes).apply()
                                        }
                                    )
                                }
                            }
                        }
                    }

                    PreferenceSection("Do Not Disturb", sectionModifier("Do Not Disturb"), highlightedSection == "Do Not Disturb") {
                        io.github.anisharyal09.anice.features.dndsync.DndSyncSettings(app.dndSync)
                    }

                    PreferenceSection("Clipboard", sectionModifier("Clipboard"), highlightedSection == "Clipboard") {
                        io.github.anisharyal09.anice.features.clipboard.ClipboardSettings(app.clipboard, peers, grouped = true)
                    }

                    if (!app.sms.granted) {
                        PreferenceSection("Messages", sectionModifier("Messages"), highlightedSection == "Messages") {
                            io.github.anisharyal09.anice.features.sms.SmsSettings(app.sms)
                        }
                    }

                    PreferenceSection("Notification sync", sectionModifier("Notification sync"), highlightedSection == "Notification sync") {
                        io.github.anisharyal09.anice.features.notifications.NotificationSettings(app.notificationMirror)
                        HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
                        val selectedCount = app.notificationMirror.preferences.selectedPackages().size
                        Row(Modifier.fillMaxWidth().heightIn(min = 52.dp)
                            .clickable(role = Role.Button, onClickLabel = "Select apps") { navigation.settingsRoute = SettingsRoute.NotificationApps }
                            .padding(vertical = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                                Text("Select apps", style = MaterialTheme.typography.bodyMedium)
                                Text(when (selectedCount) { 0 -> "No apps selected"; 1 -> "1 app selected"; else -> "$selectedCount apps selected" },
                                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                            Icon(painterResource(R.drawable.ic_chevron_forward), contentDescription = null,
                                modifier = Modifier.size(18.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                        }
                    }

                    PreferenceSection("File transfer", sectionModifier("File transfer"), highlightedSection == "File transfer") {
                        io.github.anisharyal09.anice.features.transfer.TransferAutoReceiveSettings(
                            preferences = app.transfer.autoReceivePreferences,
                            peers = peers,
                            compact = true,
                            modifier = Modifier.padding(vertical = 10.dp),
                        )
                    }

                    PreferenceSection("This device", sectionModifier("This device"), highlightedSection == "This device") {
                        Row(
                            Modifier.fillMaxWidth().heightIn(min = 52.dp)
                                .clickable(role = Role.Button, onClickLabel = "Open identity and security") {
                                    showingIdentity = true
                                }
                                .padding(vertical = 10.dp),
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                                Text(identity.state.snapshot?.identity?.deviceName ?: "This device", style = MaterialTheme.typography.bodyMedium)
                                Text("Identity and security", style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant)
                            }
                            Icon(painterResource(R.drawable.ic_chevron_forward), contentDescription = null,
                                modifier = Modifier.size(18.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
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
    val shape = RoundedCornerShape(8.dp)
    Column(modifier, verticalArrangement = Arrangement.spacedBy(7.dp)) {
        Text(title, Modifier.padding(horizontal = 2.dp), style = MaterialTheme.typography.labelMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant)
        Surface(
            modifier = Modifier.fillMaxWidth().then(
                if (highlighted) Modifier.border(1.dp, MaterialTheme.colorScheme.primary, shape) else Modifier
            ),
            shape = shape,
            color = if (highlighted) MaterialTheme.colorScheme.primaryContainer else MaterialTheme.colorScheme.surfaceContainer
        ) {
            Column(Modifier.fillMaxWidth().padding(horizontal = 12.dp), content = content)
        }
    }
}

@Composable
private fun AboutScreen(context: Context) {
    val uriHandler = LocalUriHandler.current
    val version = remember {
        context.packageManager.getPackageInfo(context.packageName, 0).versionName?.let { "Version v$it" }.orEmpty()
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
                            Text("aniCe", style = MaterialTheme.typography.titleMedium)
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
                        Text("aniCe", style = MaterialTheme.typography.titleMedium)
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
            AboutDetailRow("Report an issue", "GitHub Issues", "https://github.com/anisharyal09/aniCe/issues", uriHandler::openUri)
            BoxWithConstraints(Modifier.fillMaxWidth()) {
                if (maxWidth < 340.dp || LocalDensity.current.fontScale >= 1.4f) {
                    Column {
                        AboutDetailRow("Developer", "@anisharyal09", "https://github.com/anisharyal09", uriHandler::openUri, showDivider = false)
                        AboutProfileLinks(Modifier.align(Alignment.End), uriHandler::openUri)
                    }
                } else {
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        AboutDetailRow("Developer", "@anisharyal09", "https://github.com/anisharyal09", uriHandler::openUri,
                            modifier = Modifier.weight(1f), showDivider = false)
                        AboutProfileLinks(openUri = uriHandler::openUri)
                    }
                }
            }
            HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
            Column(Modifier.fillMaxWidth().padding(top = 16.dp), verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text("No accounts, no telemetry. The only request outside your devices is the optional update check, sent to github.com.",
                    style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Row(
                    modifier = Modifier
                        .clickable(role = Role.Button, onClickLabel = "Support aniCe") {
                            uriHandler.openUri("https://anisharyal09.com.np/support?from=anice")
                        }
                        .padding(vertical = 4.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    val contentColor = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.85f)
                    Icon(painterResource(R.drawable.ic_heart), contentDescription = null,
                        tint = contentColor, modifier = Modifier.size(13.dp))
                    Spacer(Modifier.width(6.dp))
                    Text("Support aniCe :)", style = MaterialTheme.typography.labelMedium,
                        color = contentColor)
                }
            }
        }
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
