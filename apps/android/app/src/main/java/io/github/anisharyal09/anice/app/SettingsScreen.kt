// SPDX-License-Identifier: GPL-3.0-or-later
// Presents appearance and identity settings while preserving existing preference keys and navigation.
package io.github.anisharyal09.anice.app

import android.content.Context
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.unit.dp
import io.github.anisharyal09.anice.R
import io.github.anisharyal09.anice.features.deviceidentity.*
import io.github.anisharyal09.anice.ui.theme.*

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(identity: DeviceIdentityViewModel, snackbars: SnackbarHostState, navigation: AppNavigation, context: Context) {

                        if (navigation.settingsRoute == SettingsRoute.Identity) {
                            DeviceIdentityScreen(identity.state, snackbars, identity::retry, identity::reset, onRename = identity::rename)
                        } else Column(Modifier.fillMaxSize().padding(24.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
                            Text("Appearance", style = MaterialTheme.typography.titleMedium)
                            val appearance = appearancePreference()
                            FlowRow(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                Appearance.entries.forEach { mode ->
                                    FilterChip(selected = appearance == mode,
                                        onClick = { saveAppearance(context, mode) }, label = { Text(mode.name) })
                                }
                            }
                            HorizontalDivider()
                            Row(Modifier.fillMaxWidth().clickable(role = androidx.compose.ui.semantics.Role.Button, onClickLabel = "Open this device") {
                                navigation.settingsRoute = SettingsRoute.Identity
                            }.heightIn(min = 48.dp), verticalAlignment = Alignment.CenterVertically) {
                                Column(Modifier.weight(1f)) {
                                    Text("This device", style = MaterialTheme.typography.titleMedium)
                                    Text(identity.state.snapshot?.identity?.deviceName ?: "Device identity",
                                        style = MaterialTheme.typography.bodyMedium, color = MaterialTheme.colorScheme.onSurfaceVariant)
                                }
                                Icon(painterResource(R.drawable.ic_back), contentDescription = null,
                                    modifier = Modifier.size(18.dp).graphicsLayer { rotationZ = 180f })
                            }
                        }

}
