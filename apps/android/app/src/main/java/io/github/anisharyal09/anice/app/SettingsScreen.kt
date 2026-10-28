// SPDX-License-Identifier: GPL-3.0-or-later
// Presents grouped preferences and product links while preserving existing values and navigation.
package io.github.anisharyal09.anice.app

import android.content.Context
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import io.github.anisharyal09.anice.R
import io.github.anisharyal09.anice.features.deviceidentity.DeviceIdentityViewModel
import io.github.anisharyal09.anice.ui.AutomaticConnectionToggle
import io.github.anisharyal09.anice.ui.theme.Appearance
import io.github.anisharyal09.anice.ui.theme.appearancePreference
import io.github.anisharyal09.anice.ui.theme.saveAppearance

@Composable
fun SettingsScreen(
    identity: DeviceIdentityViewModel,
    snackbars: SnackbarHostState,
    navigation: AppNavigation,
    context: Context,
    peers: List<io.github.anisharyal09.anice.infrastructure.pairing.PeerTrustRecord> = emptyList()
) {
    if (navigation.destination != AppDestination.About && navigation.settingsRoute == SettingsRoute.Identity) {
        io.github.anisharyal09.anice.features.deviceidentity.DeviceIdentityScreen(
            identity.state, snackbars, identity::retry, identity::reset, onRename = identity::rename
        )
    } else if (navigation.destination == AppDestination.About || navigation.settingsRoute == SettingsRoute.About) {
        AboutScreen(context)
    } else {
        val app = context.applicationContext as io.github.anisharyal09.anice.AniCeApplication
        val lan = app.lanSessionController
        val lanPrefs = remember { context.getSharedPreferences("lan_preferences", Context.MODE_PRIVATE) }
        var timeoutMinutes by remember { mutableIntStateOf(lanPrefs.getInt("lan_background_timeout_minutes", 0)) }
        var timeoutExpanded by remember { mutableStateOf(false) }
        var appearanceExpanded by remember { mutableStateOf(false) }
        val timeoutOptions = listOf(1 to "1 min", 3 to "3 min", 5 to "5 min", 10 to "10 min", 0 to "Never")
        val appearance = appearancePreference()

        Box(Modifier.fillMaxSize(), contentAlignment = Alignment.TopCenter) {
            Column(
                Modifier.widthIn(max = 680.dp).fillMaxWidth().verticalScroll(rememberScrollState())
                    .padding(horizontal = 16.dp, vertical = 20.dp),
                verticalArrangement = Arrangement.spacedBy(18.dp)
            ) {
                Text("Settings", style = MaterialTheme.typography.titleMedium)

                PreferenceSection("Appearance") {
                    Box {
                        Row(
                            Modifier.fillMaxWidth().heightIn(min = 52.dp)
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
                }

                PreferenceSection("Connection") {
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
                            Modifier.fillMaxWidth().heightIn(min = 52.dp)
                                .clickable(role = Role.Button, onClickLabel = "Choose background timeout") { timeoutExpanded = true },
                            verticalAlignment = Alignment.CenterVertically
                        ) {
                            Text("Background timeout", Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
                            Text(timeoutOptions.first { it.first == timeoutMinutes }.second,
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

                PreferenceSection("Clipboard") {
                    io.github.anisharyal09.anice.features.clipboard.ClipboardSettings(app.clipboard, peers, grouped = true)
                }

                if (!app.sms.granted) {
                    PreferenceSection("Messages") {
                        io.github.anisharyal09.anice.features.sms.SmsSettings(app.sms)
                    }
                }

                PreferenceSection("This device") {
                    Row(
                        Modifier.fillMaxWidth().heightIn(min = 52.dp)
                            .clickable(role = Role.Button, onClickLabel = "Open identity and security") {
                                navigation.settingsRoute = SettingsRoute.Identity
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

@Composable
private fun PreferenceSection(title: String, content: @Composable ColumnScope.() -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(7.dp)) {
        Text(title, Modifier.padding(horizontal = 2.dp), style = MaterialTheme.typography.labelMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant)
        Surface(
            modifier = Modifier.fillMaxWidth(),
            shape = RoundedCornerShape(8.dp),
            color = MaterialTheme.colorScheme.surfaceContainer
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
            Text("Connect your Mac and Android.", Modifier.padding(top = 6.dp, bottom = 16.dp),
                style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
            Row(Modifier.fillMaxWidth().heightIn(min = 56.dp), verticalAlignment = Alignment.CenterVertically) {
                Icon(painterResource(R.drawable.ic_link), contentDescription = null,
                    modifier = Modifier.size(20.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
                Spacer(Modifier.width(12.dp))
                Text("aniCe", style = MaterialTheme.typography.titleMedium)
                Spacer(Modifier.weight(1f))
                Column(horizontalAlignment = Alignment.End, verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Text("macOS + Android", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    if (version.isNotEmpty()) Text(version, style = MaterialTheme.typography.labelSmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
            HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
            AboutDetailRow("Source code", "GitHub", "https://github.com/anisharyal09/aniCe", uriHandler::openUri)
            AboutDetailRow("License", "GPL-3.0-or-later", "https://github.com/anisharyal09/aniCe/blob/main/LICENSE", uriHandler::openUri)
            AboutDetailRow("Made by", "anisharyal09", "https://anisharyal09.com.np/", uriHandler::openUri)
            IconButton(
                onClick = { uriHandler.openUri("https://anisharyal09.com.np/support?from=anice") },
                modifier = Modifier.align(Alignment.CenterHorizontally).padding(top = 14.dp).size(48.dp)
            ) {
                Icon(painterResource(R.drawable.ic_heart), contentDescription = "Support aniCe",
                    tint = MaterialTheme.colorScheme.onSurfaceVariant, modifier = Modifier.size(16.dp))
            }
        }
    }
}

@Composable
private fun AboutDetailRow(label: String, detail: String, url: String, openUri: (String) -> Unit) {
    Row(
        Modifier.fillMaxWidth().heightIn(min = 54.dp)
            .clickable(role = Role.Button, onClickLabel = "$label, $detail") { openUri(url) },
        verticalAlignment = Alignment.CenterVertically
    ) {
        Text(label, Modifier.weight(1f), style = MaterialTheme.typography.bodyMedium)
        Text(detail, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        Icon(painterResource(R.drawable.ic_external_link), contentDescription = null,
            modifier = Modifier.padding(start = 8.dp).size(16.dp), tint = MaterialTheme.colorScheme.onSurfaceVariant)
    }
    HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
}
