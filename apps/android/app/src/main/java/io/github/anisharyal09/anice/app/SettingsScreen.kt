// SPDX-License-Identifier: GPL-3.0-or-later
// Presents appearance and identity settings while preserving existing preference keys and navigation.
package io.github.anisharyal09.anice.app

import android.content.Context
import androidx.compose.foundation.clickable
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.LinkAnnotation
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextLinkStyles
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.withLink
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.dp
import io.github.anisharyal09.anice.R
import io.github.anisharyal09.anice.features.deviceidentity.*
import io.github.anisharyal09.anice.ui.theme.*

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(identity: DeviceIdentityViewModel, snackbars: SnackbarHostState, navigation: AppNavigation, context: Context) {

                        if (navigation.destination != AppDestination.About && navigation.settingsRoute == SettingsRoute.Identity) {
                            DeviceIdentityScreen(identity.state, snackbars, identity::retry, identity::reset, onRename = identity::rename)
                        } else if (navigation.destination == AppDestination.About || navigation.settingsRoute == SettingsRoute.About) {
                            Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                                Text("aniCe", style = MaterialTheme.typography.titleSmall)
                                val version = remember { context.packageManager.getPackageInfo(context.packageName, 0).versionName }
                                version?.let { Text("Version $it", style = MaterialTheme.typography.bodySmall) }
                                Text("Connect your Mac and Android.", style = MaterialTheme.typography.bodyMedium)

                                TextButton(onClick = { context.startActivity(android.content.Intent(android.content.Intent.ACTION_VIEW,
                                    android.net.Uri.parse("https://github.com/anisharyal09/aniCe"))) }) { Text("Source code") }
                                TextButton(onClick = { context.startActivity(android.content.Intent(android.content.Intent.ACTION_VIEW,
                                    android.net.Uri.parse("https://github.com/anisharyal09/aniCe/blob/main/LICENSE"))) }) { Text("License · GPL-3.0-or-later") }
                                Text(buildAnnotatedString {
                                    withLink(LinkAnnotation.Url("https://anisharyal09.com.np/", TextLinkStyles(
                                        style = SpanStyle(color = MaterialTheme.colorScheme.selectionAccent,
                                            textDecoration = TextDecoration.Underline)))) {
                                        append("@anisharyal09")
                                    }
                                }, modifier = Modifier.heightIn(min = 48.dp).wrapContentHeight(Alignment.CenterVertically),
                                    style = MaterialTheme.typography.bodySmall)
                            }
                        } else Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(16.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                            Text("Appearance", style = MaterialTheme.typography.titleSmall)
                            val appearance = appearancePreference()
                            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                Appearance.entries.forEach { mode ->
                                    FilterChip(selected = appearance == mode,
                                        onClick = { saveAppearance(context, mode) }, label = { Text(mode.name) })
                                }
                            }
                            HorizontalDivider()
                            Text("Local network (LAN)", style = MaterialTheme.typography.titleSmall)
                            Text("Disconnect after inactive in background", style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                            val lanPrefs = remember { context.getSharedPreferences("lan_preferences", Context.MODE_PRIVATE) }
                            var timeoutMinutes by remember { mutableIntStateOf(lanPrefs.getInt("lan_background_timeout_minutes", 3)) }
                            val timeoutOptions = listOf(1 to "1 min", 3 to "3 min", 5 to "5 min", 10 to "10 min", 0 to "Never")
                            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                timeoutOptions.forEach { (minutes, label) ->
                                    FilterChip(
                                        selected = timeoutMinutes == minutes,
                                        onClick = {
                                            timeoutMinutes = minutes
                                            lanPrefs.edit().putInt("lan_background_timeout_minutes", minutes).apply()
                                        },
                                        label = { Text(label) }
                                    )
                                }
                            }
                            HorizontalDivider()
                            Row(Modifier.fillMaxWidth().clickable(role = androidx.compose.ui.semantics.Role.Button, onClickLabel = "Open this device") {
                                navigation.settingsRoute = SettingsRoute.Identity
                            }.heightIn(min = 48.dp), verticalAlignment = Alignment.CenterVertically) {
                                Column(Modifier.weight(1f)) {
                                    Text("This device", style = MaterialTheme.typography.titleSmall)
                                    Text(identity.state.snapshot?.identity?.deviceName ?: "Device identity",
                                        style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                }
                                Icon(painterResource(R.drawable.ic_chevron_forward), contentDescription = null,
                                    modifier = Modifier.size(18.dp))
                            }
                        }

}
