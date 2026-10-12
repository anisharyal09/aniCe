// SPDX-License-Identifier: GPL-3.0-or-later
// Presents implemented remote Mac controls through the existing application playback owner.
package io.github.anisharyal09.anice.app

import androidx.compose.foundation.*
import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import io.github.anisharyal09.anice.features.nowplaying.MediaController
import io.github.anisharyal09.anice.features.transfer.TransferController
import io.github.anisharyal09.anice.features.transfer.TransferView

@Composable
fun FeaturesScreen(media: MediaController, transfer: TransferController, navigation: AppNavigation) {
Column(Modifier.fillMaxSize().verticalScroll(rememberScrollState()).padding(24.dp),verticalArrangement=Arrangement.spacedBy(16.dp)) {
                        if(navigation.mediaDetails) {
                            TextButton(onClick={navigation.mediaDetails=false}) { Text("Back to Features") }
                            io.github.anisharyal09.anice.features.nowplaying.MediaView(media)
                        } else {
                            TransferView(transfer)
                            Text("Mac controls",style=MaterialTheme.typography.titleMedium)
                            Surface(shape=MaterialTheme.shapes.medium,color=MaterialTheme.colorScheme.surfaceContainer, onClick={navigation.mediaDetails=true}) {
                                Column(Modifier.fillMaxWidth().padding(16.dp),verticalArrangement=Arrangement.spacedBy(6.dp)) {
                                    Text("Now Playing",style=MaterialTheme.typography.titleMedium)
                                    Text(media.playback?.title?.takeIf { it.isNotEmpty() } ?: "Playback and controls from your Mac",style=MaterialTheme.typography.bodyMedium)
                                }
                            }
                        }
                    }
}
