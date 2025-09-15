import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'pages/goggles_page.dart';
import 'pages/coach_page.dart';
import 'pages/community_page.dart';
import 'pages/profile_page.dart';

void main() => runApp(const ZeshyApp());

class ZeshyApp extends StatelessWidget {
  const ZeshyApp({super.key});

  @override
  Widget build(BuildContext context) {
    final base = ThemeData(
      useMaterial3: true,
      colorSchemeSeed: Colors.blue,
      scaffoldBackgroundColor: const Color(0xFFF7F8FA),
    );

    return MaterialApp(
      title: 'Zeshy',
      debugShowCheckedModeBanner: false,
      theme: base.copyWith(
        textTheme: base.textTheme.copyWith(
          titleLarge: const TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.2,
            color: Colors.black87,
            height: 1.2,
          ),
          headlineSmall: const TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.1,
            color: Colors.black87,
            height: 1.25,
          ),
          titleMedium: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: Colors.black87,
            height: 1.25,
          ),
          bodyLarge: const TextStyle(
            fontSize: 15,
            height: 1.35,
            color: Colors.black87,
          ),
          bodyMedium: const TextStyle(
            fontSize: 14,
            height: 1.35,
            color: Colors.black87,
          ),
          labelMedium: const TextStyle(
            fontSize: 12,
            letterSpacing: 0.2,
            color: Colors.black54,
          ),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFFF5F5F5),
          foregroundColor: Colors.black87,
          elevation: 0,
          scrolledUnderElevation: 0,
          centerTitle: true,
          titleTextStyle: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.2,
            color: Colors.black87,
            height: 1.2,
          ),
          iconTheme: IconThemeData(color: Colors.black87),
        ),
        cardTheme: base.cardTheme.copyWith(
          surfaceTintColor: Colors.white,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
        navigationBarTheme: base.navigationBarTheme.copyWith(
          backgroundColor: Colors.white,
          indicatorColor: base.colorScheme.primary.withOpacity(0.10),
          labelTextStyle: MaterialStateProperty.resolveWith((states) {
            final selected = states.contains(MaterialState.selected);
            return TextStyle(
              fontSize: 12,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              letterSpacing: 0.2,
              color: selected ? base.colorScheme.primary : Colors.black87,
            );
          }),
          iconTheme: MaterialStateProperty.resolveWith((states) {
            final selected = states.contains(MaterialState.selected);
            return IconThemeData(
              size: 24,
              color: selected ? base.colorScheme.primary : Colors.black87,
            );
          }),
        ),
      ),
      home: const MainHome(),
    );
  }
}

class MainHome extends StatefulWidget {
  const MainHome({super.key});

  @override
  State<MainHome> createState() => _MainHomeState();
}

class _MainHomeState extends State<MainHome> {
  int _currentIndex = 0;
  final Color _navBarColor = const Color(0xFFFFFFFF);

  // 关键：用 GlobalKey 捕获 CoachPage 的 State，以便从 AppBar 调它的刷新方法
  final GlobalKey<CoachPageState> _coachKey = GlobalKey<CoachPageState>();

  late final List<Widget> _pages = [
    const GogglesPage(),
    CoachPage(key: _coachKey),
    const CommunityPage(),
    const ProfilePage(),
  ];

  final _titles = const ['我的设备', 'Statistics', '社区', '个人主页'];

  @override
  Widget build(BuildContext context) {
    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
      statusBarColor: Colors.white,
      statusBarIconBrightness: Brightness.dark,
      statusBarBrightness: Brightness.light,
      systemNavigationBarColor: _navBarColor,
      systemNavigationBarIconBrightness: Brightness.dark,
    ));

    final isCoach = _currentIndex == 1;

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: Text(_titles[_currentIndex]),
        actions: [
          if (isCoach)
            IconButton(
              tooltip: '刷新（下载 IMU 并计算）',
              icon: const Icon(Icons.refresh),
              onPressed: () => _coachKey.currentState?.refreshFromAppBar(),
            ),
        ],
      ),
      body: Container(
        color: Colors.white,
        child: IndexedStack(index: _currentIndex, children: _pages),
      ),
      bottomNavigationBar: Container(
        decoration: BoxDecoration(
          color: _navBarColor,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.06),
              blurRadius: 12,
              offset: const Offset(0, -4),
            ),
          ],
        ),
        child: SafeArea(
          top: false,
          child: NavigationBar(
            selectedIndex: _currentIndex,
            onDestinationSelected: (i) => setState(() => _currentIndex = i),
            labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.visibility_outlined),
                selectedIcon: Icon(Icons.visibility),
                label: 'Goggles',
              ),
              NavigationDestination(
                icon: Icon(Icons.auto_graph_outlined),
                selectedIcon: Icon(Icons.auto_graph),
                label: 'STATS',
              ),
              NavigationDestination(
                icon: Icon(Icons.groups_2_outlined),
                selectedIcon: Icon(Icons.groups_2),
                label: 'Group',
              ),
              NavigationDestination(
                icon: Icon(Icons.person_outline),
                selectedIcon: Icon(Icons.person),
                label: 'Home',
              ),
            ],
          ),
        ),
      ),
    );
  }
}
