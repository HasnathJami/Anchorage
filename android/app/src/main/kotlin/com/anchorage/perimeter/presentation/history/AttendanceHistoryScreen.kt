package com.anchorage.perimeter.presentation.history

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowLeft
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.hilt.lifecycle.viewmodel.compose.hiltViewModel
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import com.anchorage.perimeter.R
import com.anchorage.perimeter.core.designsystem.component.AnchorageCard
import com.anchorage.perimeter.core.designsystem.component.SectionEyebrow
import com.anchorage.perimeter.core.designsystem.theme.AnchorageTheme
import com.anchorage.perimeter.domain.model.AttendanceRecord
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import kotlin.math.roundToInt

/**
 * The audit trail.
 *
 * Not required by the brief, but a geofenced check-in that leaves no reviewable
 * record is only half a feature: the point of freezing distance and accuracy
 * into every [AttendanceRecord] is that somebody can later look at them.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AttendanceHistoryRoute(
    onBack: () -> Unit,
    modifier: Modifier = Modifier,
    viewModel: AttendanceHistoryViewModel = hiltViewModel(),
) {
    val colors = AnchorageTheme.colors
    val records by viewModel.records.collectAsStateWithLifecycle()

    Scaffold(
        modifier = modifier.fillMaxSize(),
        containerColor = colors.backgroundTop,
        topBar = {
            TopAppBar(
                title = {
                    Text(
                        text = stringResource(R.string.history_title),
                        style = AnchorageTheme.typography.screenTitle,
                        color = colors.primary,
                    )
                },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(
                            imageVector = Icons.AutoMirrored.Filled.KeyboardArrowLeft,
                            contentDescription = null,
                            tint = colors.primary,
                            modifier = Modifier.size(28.dp),
                        )
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = colors.topBarSurface,
                ),
            )
        },
    ) { innerPadding ->
        Box(
            modifier = Modifier
                .fillMaxSize()
                .padding(innerPadding)
                .background(
                    Brush.verticalGradient(listOf(colors.backgroundTop, colors.backgroundBottom)),
                ),
        ) {
            if (records.isEmpty()) {
                Text(
                    text = stringResource(R.string.history_empty),
                    style = AnchorageTheme.typography.caption,
                    color = colors.textTertiary,
                    modifier = Modifier
                        .align(Alignment.Center)
                        .padding(32.dp),
                )
            } else {
                LazyColumn(
                    contentPadding = PaddingValues(16.dp),
                    verticalArrangement = Arrangement.spacedBy(10.dp),
                ) {
                    items(records, key = { it.id }) { record ->
                        HistoryRow(record)
                    }
                }
            }
        }
    }
}

@Composable
private fun HistoryRow(record: AttendanceRecord) {
    val colors = AnchorageTheme.colors
    val zoned = Instant.ofEpochMilli(record.markedAtEpochMillis).atZone(ZoneId.systemDefault())

    AnchorageCard(contentPadding = 16.dp) {
        SectionEyebrow(
            text = zoned.format(DateTimeFormatter.ofPattern("dd MMM yyyy")).uppercase(),
            trailingDotColor = colors.successArc,
        )
        Spacer(Modifier.height(10.dp))
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(
                imageVector = Icons.Outlined.CheckCircle,
                contentDescription = null,
                tint = colors.successText,
                modifier = Modifier.size(20.dp),
            )
            Spacer(Modifier.width(10.dp))
            Column(modifier = Modifier.fillMaxWidth()) {
                Text(
                    text = zoned.format(DateTimeFormatter.ofPattern("hh:mm a")),
                    style = AnchorageTheme.typography.button,
                    color = colors.textPrimary,
                )
                Text(
                    text = stringResource(
                        R.string.history_entry_distance,
                        "${record.distanceMeters.roundToInt()} m",
                        record.anchorLabel,
                    ),
                    style = AnchorageTheme.typography.caption,
                    color = colors.textTertiary,
                )
            }
        }
    }
}
