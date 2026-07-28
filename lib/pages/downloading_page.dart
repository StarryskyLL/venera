import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/image_provider/cached_image.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/network/download.dart';
import 'package:venera/utils/background_download.dart';
import 'package:venera/utils/io.dart';
import 'package:venera/utils/translations.dart';

class DownloadingPage extends StatefulWidget {
  const DownloadingPage({super.key});

  @override
  State<DownloadingPage> createState() => _DownloadingPageState();
}

class _DownloadingPageState extends State<DownloadingPage> {
  DownloadTask? firstTask;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    firstTask = LocalManager().downloadingTasks.firstOrNull;
    firstTask?.addListener(update);
  }

  @override
  void initState() {
    LocalManager().addListener(update);
    super.initState();
  }

  @override
  void dispose() {
    LocalManager().removeListener(update);
    firstTask?.removeListener(update);
    super.dispose();
  }

  void update() {
    var currentFirstTask = LocalManager().downloadingTasks.firstOrNull;
    if (currentFirstTask != firstTask) {
      firstTask?.removeListener(update);
      firstTask = currentFirstTask;
      firstTask?.addListener(update);
    }
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopUpWidgetScaffold(
      title: "",
      body: ListView.builder(
        itemCount: LocalManager().downloadingTasks.length + 1,
        itemBuilder: (BuildContext context, int i) {
          if (i == 0) {
            return buildTop();
          }
          i--;

          return _DownloadTaskTile(
            key: ValueKey(LocalManager().downloadingTasks[i]),
            task: LocalManager().downloadingTasks[i],
          );
        },
      ),
    );
  }

  Widget buildTop() {
    int speed = 0;
    if (LocalManager().downloadingTasks.isNotEmpty) {
      speed = LocalManager().downloadingTasks.first.speed;
    }
    var first = LocalManager().downloadingTasks.firstOrNull;
    return Container(
      height: 48,
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: context.colorScheme.outlineVariant,
            width: 0.6,
          ),
        ),
      ),
      child: Row(
        children: [
          if (first?.isPaused == true)
            Text("Paused".tl, style: ts.s18.bold)
          else if (first?.isError == true)
            Text("Error".tl, style: ts.s18.bold)
          else
            Text("${bytesToReadableString(speed)}/s", style: ts.s18.bold),
          const Spacer(),
          if (first?.isPaused == true || first?.isError == true)
            OutlinedButton(
              child: Row(
                children: [
                  const Icon(Icons.play_arrow, size: 18),
                  const SizedBox(width: 4),
                  Text("Start".tl),
                ],
              ),
              onPressed: () {
                first!.resume();
                BackgroundDownload.instance.sync();
              },
            )
          else if (first != null)
            OutlinedButton(
              child: Row(
                children: [
                  const Icon(Icons.pause, size: 18),
                  const SizedBox(width: 4),
                  Text("Pause".tl),
                ],
              ),
              onPressed: () {
                first.pause();
                BackgroundDownload.instance.sync();
              },
            ),
        ],
      ).paddingHorizontal(16),
    );
  }
}

class _DownloadTaskTile extends StatefulWidget {
  const _DownloadTaskTile({required this.task, super.key});

  final DownloadTask task;

  @override
  State<_DownloadTaskTile> createState() => _DownloadTaskTileState();
}

class _DownloadTaskTileState extends State<_DownloadTaskTile> {
  late DownloadTask task;

  @override
  void initState() {
    task = widget.task;
    task.addListener(update);
    super.initState();
  }

  @override
  void dispose() {
    task.removeListener(update);
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _DownloadTaskTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.task != widget.task) {
      task.removeListener(update);
      task = widget.task;
      task.addListener(update);
    }
  }

  void update() {
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final chapterTask = widget.task is ImagesDownloadTask
        ? widget.task as ImagesDownloadTask
        : null;
    return Container(
      height: 136,
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
      child: Row(
        children: [
          Container(
            width: 82,
            height: double.infinity,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              color: context.colorScheme.primaryContainer,
            ),
            clipBehavior: Clip.antiAlias,
            child: widget.task.cover == null
                ? null
                : Image(
                    image: CachedImageProvider(widget.task.cover!),
                    filterQuality: FilterQuality.medium,
                    fit: BoxFit.cover,
                  ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.task.title,
                        style: Theme.of(context).textTheme.bodyMedium,
                        maxLines: 2,
                      ),
                    ),
                    if (chapterTask?.hasChapterProgress == true)
                      Tooltip(
                        message: "Chapter Progress".tl,
                        child: IconButton(
                          icon: const Icon(Icons.view_list_outlined),
                          onPressed: () {
                            context.to(
                              () => _ChapterDownloadProgressPage(
                                task: chapterTask!,
                              ),
                            );
                          },
                        ),
                      ),
                    MenuButton(
                      entries: [
                        MenuEntry(
                          icon: Icons.close,
                          text: "Cancel".tl,
                          onClick: () {
                            widget.task.cancel();
                          },
                        ),
                        MenuEntry(
                          icon: Icons.vertical_align_top,
                          text: "Move To First".tl,
                          onClick: () {
                            LocalManager().moveToFirst(widget.task);
                          },
                        ),
                      ],
                    ),
                  ],
                ),
                const Spacer(),
                if (!widget.task.isPaused || widget.task.isError)
                  Text(widget.task.message, style: ts.s12, maxLines: 3),
                const SizedBox(height: 4),
                LinearProgressIndicator(value: widget.task.progress),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _ChapterDownloadProgressPage extends StatefulWidget {
  const _ChapterDownloadProgressPage({required this.task});

  final ImagesDownloadTask task;

  @override
  State<_ChapterDownloadProgressPage> createState() =>
      _ChapterDownloadProgressPageState();
}

class _ChapterDownloadProgressPageState
    extends State<_ChapterDownloadProgressPage> {
  bool _rebuildScheduled = false;

  @override
  void initState() {
    super.initState();
    widget.task.addListener(_update);
    LocalManager().addListener(_update);
  }

  @override
  void dispose() {
    widget.task.removeListener(_update);
    LocalManager().removeListener(_update);
    super.dispose();
  }

  void _update() {
    if (!mounted || _rebuildScheduled) return;
    _rebuildScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _rebuildScheduled = false;
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final chapters = widget.task.chapterDownloadProgress;
    final completed = chapters
        .where((item) => item.status == ChapterDownloadStatus.completed)
        .length;
    final isComplete = chapters.isNotEmpty && completed == chapters.length;

    return PopUpWidgetScaffold(
      title: "Chapter Progress".tl,
      body: Column(
        children: [
          _buildSummary(context, completed, chapters.length),
          Expanded(
            child: chapters.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const CircularProgressIndicator(),
                        const SizedBox(height: 16),
                        Text("Fetching image list".tl),
                      ],
                    ),
                  )
                : ListView.separated(
                    itemCount: chapters.length,
                    separatorBuilder: (_, _) => Divider(
                      height: 1,
                      color: context.colorScheme.outlineVariant,
                    ),
                    itemBuilder: (context, index) =>
                        _ChapterProgressTile(progress: chapters[index]),
                  ),
          ),
          _buildControls(context, isComplete),
        ],
      ),
    );
  }

  Widget _buildSummary(BuildContext context, int completed, int total) {
    final speed = widget.task.speed;
    final isError = widget.task.isError;
    final isComplete = total > 0 && completed == total;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
      decoration: BoxDecoration(
        color: context.colorScheme.surfaceContainerLow,
        border: Border(
          bottom: BorderSide(color: context.colorScheme.outlineVariant),
        ),
      ),
      child: Row(
        children: [
          Icon(
            isComplete
                ? Icons.check_circle_outline
                : isError
                ? Icons.error_outline
                : widget.task.isPaused
                ? Icons.pause_circle_outline
                : Icons.download,
            color: isError
                ? context.colorScheme.error
                : isComplete
                ? context.colorScheme.tertiary
                : context.colorScheme.primary,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.task.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ts.s14.bold,
                ),
                const SizedBox(height: 2),
                Text(
                  isComplete
                      ? "Completed".tl
                      : isError
                      ? "Error".tl
                      : widget.task.isPaused
                      ? "Paused".tl
                      : "${bytesToReadableString(speed)}/s",
                  style: ts.s12.copyWith(
                    color: context.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          Text("$completed/$total", style: ts.s16.bold),
        ],
      ),
    );
  }

  Widget _buildControls(BuildContext context, bool isComplete) {
    final taskExists = LocalManager().downloadingTasks.contains(widget.task);
    final canStart =
        taskExists &&
        !isComplete &&
        (widget.task.isPaused || widget.task.isError);
    final canPause =
        taskExists &&
        !isComplete &&
        !widget.task.isPaused &&
        !widget.task.isError;
    return SafeArea(
      top: false,
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        decoration: BoxDecoration(
          color: context.colorScheme.surface,
          border: Border(
            top: BorderSide(color: context.colorScheme.outlineVariant),
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: FilledButton.tonalIcon(
                onPressed: canStart
                    ? () {
                        widget.task.resume();
                        BackgroundDownload.instance.sync();
                      }
                    : null,
                icon: const Icon(Icons.play_arrow),
                label: Text("Start All".tl),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: canPause
                    ? () {
                        widget.task.pause();
                        BackgroundDownload.instance.sync();
                      }
                    : null,
                icon: const Icon(Icons.pause),
                label: Text("Pause All".tl),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChapterProgressTile extends StatelessWidget {
  const _ChapterProgressTile({required this.progress});

  final ChapterDownloadProgress progress;

  @override
  Widget build(BuildContext context) {
    final statusColor = _statusColor(context);
    final totalText = progress.total == 0 ? "--" : progress.total.toString();
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 104),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text(
                    progress.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  "${progress.current}/$totalText",
                  style: ts.s14.bold.copyWith(
                    color: context.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              _statusText(),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: ts.s12.copyWith(color: statusColor),
            ),
            const SizedBox(height: 8),
            _buildProgressIndicator(),
          ],
        ),
      ),
    );
  }

  Widget _buildProgressIndicator() {
    if (progress.status == ChapterDownloadStatus.fetching) {
      return LinearProgressIndicator(
        minHeight: 4,
        borderRadius: BorderRadius.circular(2),
      );
    }
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: progress.progress),
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOutCubic,
      builder: (context, value, child) => LinearProgressIndicator(
        value: value,
        minHeight: 4,
        borderRadius: BorderRadius.circular(2),
      ),
    );
  }

  String _statusText() {
    switch (progress.status) {
      case ChapterDownloadStatus.waiting:
        return "Waiting".tl;
      case ChapterDownloadStatus.fetching:
        return "Fetching image list".tl;
      case ChapterDownloadStatus.downloading:
        return "Downloading".tl;
      case ChapterDownloadStatus.paused:
        return "Paused".tl;
      case ChapterDownloadStatus.completed:
        return "Completed".tl;
      case ChapterDownloadStatus.error:
        final message = progress.errorMessage;
        return message == null ? "Error".tl : "${"Error".tl}: $message";
    }
  }

  Color _statusColor(BuildContext context) {
    switch (progress.status) {
      case ChapterDownloadStatus.downloading:
      case ChapterDownloadStatus.fetching:
        return context.colorScheme.primary;
      case ChapterDownloadStatus.completed:
        return context.colorScheme.tertiary;
      case ChapterDownloadStatus.error:
        return context.colorScheme.error;
      case ChapterDownloadStatus.waiting:
      case ChapterDownloadStatus.paused:
        return context.colorScheme.onSurfaceVariant;
    }
  }
}
