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
    // 先构建一个基础主题，再进行精修，避免从零手搓导致的细节遗漏
    final base = ThemeData(
      useMaterial3: true,
      colorSchemeSeed: Colors.blue,
      scaffoldBackgroundColor: const Color(0xFFF7F8FA),
    );

    return MaterialApp(
      title: 'Zeshy',
      debugShowCheckedModeBanner: false,
      theme: base.copyWith(
        // —— 全局文字排版（更大厂范儿）——
        textTheme: base.textTheme.copyWith(
          // 页面主标题（用于 AppBar）
          titleLarge: const TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.2,
            color: Colors.black87,
            height: 1.2,
          ),
          // 卡片区块标题、副标题
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
          // 正文排版更通透
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

        // —— AppBar 视觉（沉稳、无滚动阴影）——
        appBarTheme: const AppBarTheme(
          backgroundColor: const Color(0xFFF5F5F5),
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

        // —— 卡片圆角与材质（更干净）——
        cardTheme: base.cardTheme.copyWith(
          surfaceTintColor: Colors.white,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),

        // —— 底部导航更克制（选中加粗）——
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

  final _pages = const [
    GogglesPage(),
    CoachPage(),
    CommunityPage(),
    ProfilePage(),
  ];

  final _titles = const ['我的设备', '目标: Temedog', '社区', '个人主页'];

  @override
  Widget build(BuildContext context) {
    // 状态栏白色 + 深色图标；底部系统导航栏与菜单同色
    SystemChrome.setSystemUIOverlayStyle(SystemUiOverlayStyle(
      statusBarColor: Colors.white,
      statusBarIconBrightness: Brightness.dark,
      statusBarBrightness: Brightness.light,
      systemNavigationBarColor: _navBarColor,
      systemNavigationBarIconBrightness: Brightness.dark,
    ));

    return Scaffold(
      // 中间内容区域白底
      backgroundColor: Colors.white,

      appBar: AppBar(
        title: Text(_titles[_currentIndex]),
      ),

      // 内容区再包一层白底，保证子页面没设背景时也干净
      body: Container(
        color: Colors.white,
        child: IndexedStack(index: _currentIndex, children: _pages),
      ),

      // 底部导航加“向上阴影”分界
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
                label: '雪镜',
              ),
              NavigationDestination(
                icon: Icon(Icons.auto_graph_outlined),
                selectedIcon: Icon(Icons.auto_graph),
                label: 'AI教练',
              ),
              NavigationDestination(
                icon: Icon(Icons.groups_2_outlined),
                selectedIcon: Icon(Icons.groups_2),
                label: '社区',
              ),
              NavigationDestination(
                icon: Icon(Icons.person_outline),
                selectedIcon: Icon(Icons.person),
                label: '个人主页',
              ),
            ],
          ),
        ),
      ),
    );
  }
}
