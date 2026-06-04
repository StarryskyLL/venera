import 'package:flutter/material.dart';
import 'package:venera/components/components.dart';
import 'package:venera/foundation/app.dart';
import 'package:venera/foundation/image_provider/cached_image.dart';
import 'package:venera/foundation/local.dart';
import 'package:venera/network/download.dart';
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
    var hasDetails = widget.task.chapterProgresses.isNotEmpty;
    var child = Container(
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
                    if (hasDetails)
                      Icon(
                        Icons.chevron_right,
                        color: context.colorScheme.onSurfaceVariant,
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
    if (!hasDetails) {
      return child;
    }
    return InkWell(
      onTap: () {
        context.to(() => _DownloadChapterProgressPage(task: widget.task));
      },
      child: child,
    );
  }
}

class _DownloadChapterProgressPage extends StatefulWidget {
  const _DownloadChapterProgressPage({required this.task});

  final DownloadTask task;

  @override
  State<_DownloadChapterProgressPage> createState() =>
      _DownloadChapterProgressPageState();
}

class _DownloadChapterProgressPageState
    extends State<_DownloadChapterProgressPage> {
  late DownloadTask task;

  @override
  void initState() {
    super.initState();
    task = widget.task;
    task.addListener(update);
  }

  @override
  void dispose() {
    task.removeListener(update);
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _DownloadChapterProgressPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.task != widget.task) {
      task.removeListener(update);
      task = widget.task;
      task.addListener(update);
    }
  }

  void update() {
    if (mounted) {
      setState(() {});
    }
  }

  @override
  Widget build(BuildContext context) {
    var chapters = task.chapterProgresses;
    var isFirstTask = LocalManager().downloadingTasks.firstOrNull == task;
    return Scaffold(
      body: SmoothCustomScrollView(
        slivers: [
          SliverAppbar(
            style: AppbarStyle.shadow,
            title: Text(task.title),
            actions: [
              if (isFirstTask)
                if (task.isPaused || task.isError)
                  Tooltip(
                    message: "Start".tl,
                    child: IconButton(
                      icon: const Icon(Icons.play_arrow),
                      onPressed: task.resume,
                    ),
                  )
                else
                  Tooltip(
                    message: "Pause".tl,
                    child: IconButton(
                      icon: const Icon(Icons.pause),
                      onPressed: task.pause,
                    ),
                  ),
            ],
          ),
          SliverToBoxAdapter(child: _DownloadChapterProgressHeader(task: task)),
          if (chapters.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(child: Text("Chapters".tl)),
            )
          else
            SliverList(
              delegate: SliverChildBuilderDelegate((context, index) {
                return _DownloadChapterProgressTile(
                  progress: chapters[index],
                  task: task,
                );
              }, childCount: chapters.length),
            ),
        ],
      ),
    );
  }
}

class _DownloadChapterProgressHeader extends StatelessWidget {
  const _DownloadChapterProgressHeader({required this.task});

  final DownloadTask task;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: context.colorScheme.outlineVariant,
            width: 0.6,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  task.message,
                  style: ts.s14.withColor(context.colorScheme.onSurfaceVariant),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 12),
              Text(
                task.isPaused || task.isError
                    ? (task.isError ? "Error".tl : "Paused".tl)
                    : "${bytesToReadableString(task.speed)}/s",
                style: ts.s14.bold,
              ),
            ],
          ),
          const SizedBox(height: 10),
          LinearProgressIndicator(value: task.progress),
        ],
      ),
    );
  }
}

class _DownloadChapterProgressTile extends StatelessWidget {
  const _DownloadChapterProgressTile({
    required this.progress,
    required this.task,
  });

  final DownloadChapterProgress progress;

  final DownloadTask task;

  String get statusText {
    if (progress.isCompleted) {
      return "Completed".tl;
    }
    if (task.isError) {
      return "Error".tl;
    }
    if (task.isPaused) {
      return "Paused".tl;
    }
    if (progress.isRunning && !progress.hasImageList) {
      return "Fetching image list...".tl;
    }
    if (progress.isRunning) {
      return "Downloading".tl;
    }
    return "Waiting".tl;
  }

  @override
  Widget build(BuildContext context) {
    var total = progress.total;
    var countText = total == null
        ? "${progress.downloaded}/?"
        : "${progress.downloaded}/$total";
    var progressValue = progress.isRunning && !progress.hasImageList
        ? null
        : progress.isCompleted
        ? 1.0
        : progress.progress ?? 0.0;
    var statusColor = progress.isCompleted
        ? context.colorScheme.primary
        : progress.isRunning
        ? context.colorScheme.tertiary
        : context.colorScheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(
            color: context.colorScheme.outlineVariant,
            width: 0.6,
          ),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            progress.title,
            style: ts.s16.bold,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: Text(
                  statusText,
                  style: ts.s12.withColor(statusColor),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 12),
              Text(
                countText,
                style: ts.s14.withColor(context.colorScheme.onSurfaceVariant),
              ),
            ],
          ),
          const SizedBox(height: 8),
          LinearProgressIndicator(value: progressValue),
        ],
      ),
    );
  }
}
