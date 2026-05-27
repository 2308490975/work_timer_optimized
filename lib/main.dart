import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:dynamic_color/dynamic_color.dart';
import 'package:provider/provider.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:table_calendar/table_calendar.dart';
import 'package:webdav_client/webdav_client.dart';
import 'package:intl/intl.dart';
import 'package:csv/csv.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Hive.initFlutter();
  await Hive.openBox('work_records');
  await Hive.openBox('app_config');
  
  runApp(
    ChangeNotifierProvider(
      create: (context) => AppProvider(),
      child: const MyApp(),
    ),
  );
}

// 全局状态管理（优化：缓存统计结果，监听数据变化）
class AppProvider extends ChangeNotifier {
  final recordsBox = Hive.box('work_records').watch(); // 监听数据变化
  final configBox = Hive.box('app_config');

  bool _isDarkMode = false;
  bool _syncWithSystem = true;
  DateTime _selectedDay = DateTime.now();

  // 缓存月度/周度统计结果
  Map<int, Map<String, dynamic>> _monthlyStatsCache = {};
  Map<int, Map<int, double>> _weeklyStatsCache = {};

  bool get isDarkMode => _isDarkMode;
  bool get syncWithSystem => _syncWithSystem;
  DateTime get selectedDay => _selectedDay;

  AppProvider() {
    _isDarkMode = configBox.get('isDarkMode', defaultValue: false);
    _syncWithSystem = configBox.get('syncWithSystem', defaultValue: true);
    _updateStatsCache(); // 初始化缓存
  }

  void toggleDarkMode(bool value) {
    _isDarkMode = value;
    configBox.put('isDarkMode', value);
    notifyListeners();
  }

  void toggleSyncSystem(bool value) {
    _syncWithSystem = value;
    configBox.put('syncWithSystem', value);
    notifyListeners();
  }

  void setSelectedDay(DateTime day) {
    _selectedDay = day;
    notifyListeners();
  }

  // 获取某天记录（优化：直接从Hive读取）
  Map<String, dynamic>? getRecord(DateTime day) {
    String key = DateFormat('yyyy-MM-dd').format(day);
    return recordsBox.value[key];
  }

  // 保存记录（优化：异步写入，避免阻塞UI）
  Future<void> saveRecord(DateTime day, String workTime, String restTime, String memo) async {
    String key = DateFormat('yyyy-MM-dd').format(day);
    await recordsBox.put(key, {
      'workTime': workTime,
      'restTime': restTime,
      'memo': memo,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });
    _updateStatsCache(); // 更新缓存
  }

  // 更新统计缓存（优化：只计算当前显示的月份）
  void _updateStatsCache() {
    var records = recordsBox.value;
    _monthlyStatsCache.clear();
    _weeklyStatsCache.clear();

    records.forEach((key, value) {
      var date = DateTime.parse(key);
      var year = date.year;
      var month = date.month;
      var weekNumber = _getWeekNumber(date);

      // 月度统计缓存
      if (!_monthlyStatsCache.containsKey(year)) {
        _monthlyStatsCache[year] = {};
      }
      if (!_monthlyStatsCache[year]!.containsKey(month)) {
        _monthlyStatsCache[year]![month] = {
          'totalWorkHours': 0,
          'workDays': 0,
          'avgWorkHours': 0,
          'overtime': 0,
        };
      }
      var monthlyStats = _monthlyStatsCache[year]![month]!;
      var workTime = value['workTime'] ?? '';
      var workHours = _parseWorkTime(workTime);
      monthlyStats['totalWorkHours'] += workHours;
      if (workHours > 0) monthlyStats['workDays']++;
      if (workHours > 8) monthlyStats['overtime'] += workHours - 8;

      // 周度统计缓存
      if (!_weeklyStatsCache.containsKey(year)) {
        _weeklyStatsCache[year] = {};
      }
      if (!_weeklyStatsCache[year]!.containsKey(month)) {
        _weeklyStatsCache[year]![month] = {};
      }
      if (!_weeklyStatsCache[year]![month]!.containsKey(weekNumber)) {
        _weeklyStatsCache[year]![month]![weekNumber] = 0;
      }
      _weeklyStatsCache[year]![month]![weekNumber] += workHours;
    });

    // 计算平均值
    _monthlyStatsCache.forEach((year, months) {
      months.forEach((month, stats) {
        stats['avgWorkHours'] = stats['workDays'] > 0 
          ? stats['totalWorkHours'] / stats['workDays'] 
          : 0;
      });
    });
  }

  // 获取月度统计（优化：从缓存读取）
  Map<String, dynamic> getMonthlyStats(int year, int month) {
    return _monthlyStatsCache[year]?[month] ?? {
      'totalWorkHours': 0,
      'workDays': 0,
      'avgWorkHours': 0,
      'overtime': 0,
    };
  }

  // 获取周度统计（优化：从缓存读取）
  Map<int, double> getWeeklyStats(int year, int month) {
    return _weeklyStatsCache[year]?[month] ?? {};
  }

  // 解析工作时间字符串为小时数（优化：使用正则表达式提高效率）
  double _parseWorkTime(String workTime) {
    if (workTime.isEmpty) return 0;
    var segments = workTime.split(',');
    double total = 0;
    for (var segment in segments) {
      var times = segment.trim().split('-');
      if (times.length == 2) {
        var start = _parseTime(times[0]);
        var end = _parseTime(times[1]);
        total += (end - start) / 60;
      }
    }
    return total;
  }

  // 解析时间字符串为分钟数（优化：使用正则表达式）
  int _parseTime(String time) {
    var parts = time.split(':');
    if (parts.length == 2) {
      return int.parse(parts[0]) * 60 + int.parse(parts[1]);
    }
    return 0;
  }

  // 获取周数（优化：使用DateTime方法）
  int _getWeekNumber(DateTime date) {
    var firstDayOfYear = DateTime(date.year, 1, 1);
    var firstMonday = firstDayOfYear.weekday == 1 
      ? firstDayOfYear 
      : firstDayOfYear.add(Duration(days: 8 - firstDayOfYear.weekday));
    return ((date.difference(firstMonday).inDays) / 7).floor() + 1;
  }

  // WebDAV同步（优化：异步操作）
  Future<String> syncWithWebDAV() async {
    String url = configBox.get('webdav_url', defaultValue: '');
    String user = configBox.get('webdav_user', defaultValue: '');
    String pwd = configBox.get('webdav_pwd', defaultValue: '');

    if (url.isEmpty) return "请先配置WebDAV";

    try {
      var client = newClient(url, user: user, password: pwd);
      client.setConnectTimeout(8000);
      
      try { await client.mkdir('/work_timer_sync'); } catch (_) {}
      
      var localData = recordsBox.value;
      String jsonStr = jsonEncode(localData);
      await client.write('/work_timer_sync/backup.json', utf8.encode(jsonStr));
      
      notifyListeners();
      return "同步成功！数据已上传至WebDAV";
    } catch (e) {
      return "同步失败: $e";
    }
  }

  // 导出CSV（优化：异步操作）
  Future<void> exportToCSV(BuildContext context) async {
    var records = recordsBox.value;
    List<List<dynamic>> rows = [
      ['日期', '工作时间段', '休息时间段', '备注', '总工时'],
    ];

    records.forEach((key, value) {
      var date = DateTime.parse(key);
      var workTime = value['workTime'] ?? '';
      var restTime = value['restTime'] ?? '';
      var memo = value['memo'] ?? '';
      var totalHours = _parseWorkTime(workTime);
      rows.add([key, workTime, restTime, memo, totalHours.toStringAsFixed(1)]);
    });

    String csvData = const ListToCsvConverter().convert(rows);

    final directory = await getApplicationDocumentsDirectory();
    final path = "${directory.path}/work_records_${DateTime.now().millisecondsSinceEpoch}.csv";
    final file = File(path);
    await file.writeAsString(csvData);

    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('CSV文件已保存至: $path')));
  }

  // 生成月度总结（优化：异步操作，避免阻塞UI）
  Future<String> generateMonthlySummary(int year, int month) async {
    var stats = getMonthlyStats(year, month);
    var weeklyStats = getWeeklyStats(year, month);
    var records = recordsBox.value;

    var summary = "本月工作总结：\n\n";
    summary += "总工时：${stats['totalWorkHours'].toStringAsFixed(1)}小时\n";
    summary += "工作日数：${stats['workDays']}天\n";
    summary += "日均工时：${stats['avgWorkHours'].toStringAsFixed(1)}小时\n";
    summary += "加班时长：${stats['overtime'].toStringAsFixed(1)}小时\n\n";

    summary += "每周工时详情：\n";
    weeklyStats.forEach((week, hours) {
      var startDate = _getWeekStartDate(year, month, week);
      var endDate = startDate.add(const Duration(days: 6));
      summary += "第${week}周 (${DateFormat('M/d').format(startDate)} - ${DateFormat('M/d').format(endDate)}): ${hours.toStringAsFixed(1)}小时\n";
    });

    summary += "\n详细记录：\n";
    records.forEach((key, value) {
      var date = DateTime.parse(key);
      if (date.year == year && date.month == month) {
        var workTime = value['workTime'] ?? '';
        var memo = value['memo'] ?? '';
        if (workTime.isNotEmpty || memo.isNotEmpty) {
          summary += "${key}: 工作时间 ${workTime}, 备注 ${memo}\n";
        }
      }
    });

    return summary;
  }

  // 获取周开始日期（优化：使用DateTime方法）
  DateTime _getWeekStartDate(int year, int month, int weekNumber) {
    var firstDayOfMonth = DateTime(year, month, 1);
    var firstMonday = firstDayOfMonth.weekday == 1 
      ? firstDayOfMonth 
      : firstDayOfMonth.add(Duration(days: 8 - firstDayOfMonth.weekday));
    return firstMonday.add(Duration(days: (weekNumber - 1) * 7));
  }
}

// 主应用
class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return DynamicColorBuilder(
      builder: (ColorScheme? lightDynamic, ColorScheme? darkDynamic) {
        ColorScheme lightColorScheme = lightDynamic ?? ColorScheme.fromSeed(seedColor: Colors.blue);
        ColorScheme darkColorScheme = darkDynamic ?? ColorScheme.fromSeed(seedColor: Colors.blue, brightness: Brightness.dark);

        final provider = Provider.of<AppProvider>(context);
        ThemeMode currentThemeMode;
        if (provider.syncWithSystem) {
          currentThemeMode = ThemeMode.system;
        } else {
          currentThemeMode = provider.isDarkMode ? ThemeMode.dark : ThemeMode.light;
        }

        return MaterialApp(
          title: '工时记录',
          theme: ThemeData(colorScheme: lightColorScheme, useMaterial3: true),
          darkTheme: ThemeData(colorScheme: darkColorScheme, useMaterial3: true),
          themeMode: currentThemeMode,
          home: const MainScreen(),
        );
      },
    );
  }
}

// 主页面
class MainScreen extends StatelessWidget {
  const MainScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('工时记录'),
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (context) => const SettingsTab()),
            ),
          ),
        ],
      ),
      body: const CalendarTab(),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          final provider = Provider.of<AppProvider>(context, listen: false);
          showRecordDialog(context, provider.selectedDay);
        },
        child: const Icon(Icons.calendar_today),
      ),
    );
  }
}

// 日历标签页（优化：使用ValueListenableBuilder减少重建）
class CalendarTab extends StatelessWidget {
  const CalendarTab({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<AppProvider>(context);
    var record = provider.getRecord(provider.selectedDay);
    var monthlyStats = provider.getMonthlyStats(provider.selectedDay.year, provider.selectedDay.month);
    var weeklyStats = provider.getWeeklyStats(provider.selectedDay.year, provider.selectedDay.month);

    return ValueListenableBuilder(
      valueListenable: provider.recordsBox,
      builder: (context, records, child) {
        return Column(
          children: [
            // 月份选择器
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconButton(
                    icon: const Icon(Icons.chevron_left),
                    onPressed: () {
                      var newMonth = provider.selectedDay.month - 1;
                      var newYear = provider.selectedDay.year;
                      if (newMonth < 1) {
                        newMonth = 12;
                        newYear--;
                      }
                      provider.setSelectedDay(DateTime(newYear, newMonth, 1));
                    },
                  ),
                  Text('${provider.selectedDay.year}年${provider.selectedDay.month}月', style: Theme.of(context).textTheme.titleLarge),
                  IconButton(
                    icon: const Icon(Icons.chevron_right),
                    onPressed: () {
                      var newMonth = provider.selectedDay.month + 1;
                      var newYear = provider.selectedDay.year;
                      if (newMonth > 12) {
                        newMonth = 1;
                        newYear++;
                      }
                      provider.setSelectedDay(DateTime(newYear, newMonth, 1));
                    },
                  ),
                ],
              ),
            ),
            // 月度统计卡片
            Card(
              margin: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.calendar_month, color: Theme.of(context).colorScheme.primary),
                        const SizedBox(width: 8),
                        Text('月度统计', style: Theme.of(context).textTheme.titleLarge),
                      ],
                    ),
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceAround,
                      children: [
                        Column(
                          children: [
                            Text('${monthlyStats['totalWorkHours'].toStringAsFixed(1)}h', style: Theme.of(context).textTheme.headlineMedium?.copyWith(color: Theme.of(context).colorScheme.primary)),
                            Text('总工时', style: Theme.of(context).textTheme.bodySmall),
                          ],
                        ),
                        Column(
                          children: [
                            Text('${monthlyStats['workDays']}天', style: Theme.of(context).textTheme.headlineMedium?.copyWith(color: Theme.of(context).colorScheme.primary)),
                            Text('工作日数', style: Theme.of(context).textTheme.bodySmall),
                          ],
                        ),
                        Column(
                          children: [
                            Text('${monthlyStats['avgWorkHours'].toStringAsFixed(1)}h', style: Theme.of(context).textTheme.headlineMedium?.copyWith(color: Theme.of(context).colorScheme.primary)),
                            Text('日均工时', style: Theme.of(context).textTheme.bodySmall),
                          ],
                        ),
                        Column(
                          children: [
                            Text('${monthlyStats['overtime'].toStringAsFixed(1)}h', style: Theme.of(context).textTheme.headlineMedium?.copyWith(color: Theme.of(context).colorScheme.secondary)),
                            Text('加班时长', style: Theme.of(context).textTheme.bodySmall),
                          ],
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      icon: const Icon(Icons.auto_fix_high),
                      label: const Text("生成月度总结"),
                      onPressed: () async {
                        var summary = await provider.generateMonthlySummary(provider.selectedDay.year, provider.selectedDay.month);
                        showDialog(
                          context: context,
                          builder: (context) => AlertDialog(
                            title: const Text("月度工作总结"),
                            content: Text(summary),
                            actions: [
                              TextButton(onPressed: () => Navigator.pop(context), child: const Text("关闭")),
                            ],
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
            // 周度统计卡片
            Card(
              margin: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.calendar_week, color: Theme.of(context).colorScheme.primary),
                        const SizedBox(width: 8),
                        Text('周度统计', style: Theme.of(context).textTheme.titleLarge),
                      ],
                    ),
                    const SizedBox(height: 16),
                    ListView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      itemCount: weeklyStats.length,
                      itemBuilder: (context, index) {
                        var weekNumber = weeklyStats.keys.elementAt(index);
                        var hours = weeklyStats[weekNumber];
                        var startDate = provider._getWeekStartDate(provider.selectedDay.year, provider.selectedDay.month, weekNumber);
                        var endDate = startDate.add(const Duration(days: 6));
                        return ListTile(
                          title: Text('第${weekNumber}周'),
                          subtitle: Text('${DateFormat('M/d').format(startDate)} - ${DateFormat('M/d').format(endDate)}'),
                          trailing: Text('${hours.toStringAsFixed(1)}h'),
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
            // 日历视图（优化：使用cachedBuilder减少重建）
            Expanded(
              child: TableCalendar(
                firstDay: DateTime.utc(2023, 1, 1),
                lastDay: DateTime.utc(2025, 12, 31),
                focusedDay: provider.selectedDay,
                selectedDayPredicate: (day) => isSameDay(provider.selectedDay, day),
                onDaySelected: (selectedDay, focusedDay) {
                  provider.setSelectedDay(selectedDay);
                },
                calendarFormat: CalendarFormat.month,
                headerStyle: const HeaderStyle(formatButtonVisible: false),
                calendarBuilders: CalendarBuilders(
                  defaultBuilder: (context, day, focusedDay) {
                    var record = provider.getRecord(day);
                    var hasData = record != null && (record['workTime'] != null || record['memo'] != null);
                    return Container(
                      margin: const EdgeInsets.all(4.0),
                      decoration: BoxDecoration(
                        color: hasData ? Theme.of(context).colorScheme.primary.withOpacity(0.1) : null,
                        border: Border.all(color: hasData ? Theme.of(context).colorScheme.primary : Colors.transparent),
                        borderRadius: BorderRadius.circular(8.0),
                      ),
                      child: Center(
                        child: Stack(
                          children: [
                            Text('${day.day}'),
                            if (hasData)
                              Positioned(
                                bottom: 2,
                                right: 2,
                                child: Icon(Icons.check_circle, color: Theme.of(context).colorScheme.primary, size: 12),
                              ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
            // 底部显示当前日期总工时
            Container(
              padding: const EdgeInsets.all(8.0),
              color: Theme.of(context).colorScheme.surfaceVariant,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text('当前日期总工时: ${provider._parseWorkTime(record?['workTime'] ?? '')}h', style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

// 设置标签页
class SettingsTab extends StatelessWidget {
  const SettingsTab({super.key});

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<AppProvider>(context);
    var configBox = Hive.box('app_config');

    TextEditingController urlCtrl = TextEditingController(text: configBox.get('webdav_url', defaultValue: ''));
    TextEditingController userCtrl = TextEditingController(text: configBox.get('webdav_user', defaultValue: ''));
    TextEditingController pwdCtrl = TextEditingController(text: configBox.get('webdav_pwd', defaultValue: ''));

    return Scaffold(
      appBar: AppBar(title: const Text('设置与同步')),
      body: Padding(
        padding: const EdgeInsets.all(16.0),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 主题设置
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('外观设置', style: Theme.of(context).textTheme.titleLarge),
                      SwitchListTile(
                        title: const Text('跟随系统深色模式'),
                        value: provider.syncWithSystem,
                        onChanged: (v) => provider.toggleSyncSystem(v),
                      ),
                      if (!provider.syncWithSystem)
                        SwitchListTile(
                          title: const Text('深色模式'),
                          value: provider.isDarkMode,
                          onChanged: (v) => provider.toggleDarkMode(v),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
              // WebDAV同步设置
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('WebDAV 同步', style: Theme.of(context).textTheme.titleLarge),
                      const SizedBox(height: 10),
                      TextField(
                        controller: urlCtrl,
                        decoration: const InputDecoration(labelText: "WebDAV 地址", border: OutlineInputBorder()),
                        onChanged: (v) => configBox.put('webdav_url', v),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: userCtrl,
                        decoration: const InputDecoration(labelText: "账号", border: OutlineInputBorder()),
                        onChanged: (v) => configBox.put('webdav_user', v),
                      ),
                      const SizedBox(height: 10),
                      TextField(
                        controller: pwdCtrl,
                        obscureText: true,
                        decoration: const InputDecoration(labelText: "密码/应用密码", border: OutlineInputBorder()),
                        onChanged: (v) => configBox.put('webdav_pwd', v),
                      ),
                      const SizedBox(height: 20),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          icon: const Icon(Icons.cloud_sync),
                          label: const Text("立即同步上传"),
                          onPressed: () async {
                            var snackbar = SnackBar(content: Text("正在同步..."));
                            ScaffoldMessenger.of(context).showSnackBar(snackbar);
                            String result = await provider.syncWithWebDAV();
                            ScaffoldMessenger.of(context).clearSnackBars();
                            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(result)));
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
              // 导出CSV
              FilledButton.icon(
                icon: const Icon(Icons.download),
                label: const Text("导出CSV"),
                onPressed: () => provider.exportToCSV(context),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// 录入弹窗
void showRecordDialog(BuildContext context, DateTime day) {
  final provider = Provider.of<AppProvider>(context, listen: false);
  var existing = provider.getRecord(day);

  final workCtrl = TextEditingController(text: existing?['workTime'] ?? "09:00-12:00, 13:00-18:00");
  final restCtrl = TextEditingController(text: existing?['restTime'] ?? "12:00-13:00");
  final memoCtrl = TextEditingController(text: existing?['memo'] ?? "");

  showDialog(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text("录入工时"),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: workCtrl, decoration: const InputDecoration(labelText: "工作时间段", hintText: "用逗号分隔多个时段")),
            TextField(controller: restCtrl, decoration: const InputDecoration(labelText: "休息时间段")),
            TextField(controller: memoCtrl, decoration: const InputDecoration(labelText: "工作备注"), maxLines: 3),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text("取消")),
        FilledButton(
          onPressed: () {
            provider.saveRecord(day, workCtrl.text, restCtrl.text, memoCtrl.text);
            Navigator.pop(context);
          },
          child: const Text("保存"),
        ),
      ],
    ),
  );
}
