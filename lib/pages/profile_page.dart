import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';

class ProfilePage extends StatefulWidget {
  const ProfilePage({super.key});

  @override
  State<ProfilePage> createState() => _ProfilePageState();
}

class _ProfilePageState extends State<ProfilePage> {
  final ImagePicker _picker = ImagePicker();

  XFile? _bgFile;
  XFile? _avatarFile;
  String _name = '极限玩家';

  Future<void> _pickBackground() async {
    final file = await _picker.pickImage(source: ImageSource.gallery);
    if (file != null && mounted) {
      setState(() => _bgFile = file);
      _toast('已更新背景图');
    }
  }

  Future<void> _pickAvatar() async {
    final file = await _picker.pickImage(source: ImageSource.gallery);
    if (file != null && mounted) {
      setState(() => _avatarFile = file);
      _toast('已更新头像');
    }
  }

  Future<void> _editName() async {
    final ctrl = TextEditingController(text: _name);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('修改昵称'),
        content: TextField(
          controller: ctrl,
          maxLength: 20,
          decoration: const InputDecoration(hintText: '输入新的昵称'),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('保存')),
        ],
      ),
    );
    if (ok == true && mounted) {
      final v = ctrl.text.trim();
      if (v.isNotEmpty) {
        setState(() => _name = v);
        _toast('昵称已更新');
      }
    }
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  @override
  Widget build(BuildContext context) {
    final bg = _bgFile != null
        ? DecorationImage(image: FileImage(File(_bgFile!.path)), fit: BoxFit.cover)
        : const DecorationImage(
      image: AssetImage('assets/pictures/profile_bg_placeholder.jpg'), // 没有就换成你项目内的占位图
      fit: BoxFit.cover,
    );

    final avatarProvider = _avatarFile != null
        ? FileImage(File(_avatarFile!.path))
        : const AssetImage('assets/pictures/avatar_placeholder.jpg') as ImageProvider<Object>;

    return Scaffold(
      body: SafeArea(
        child: CustomScrollView(
          slivers: [
            // 顶部背景 + 头像 + 名称
            SliverToBoxAdapter(
              child: Stack(
                children: [
                  // 背景
                  Container(
                    height: 260,
                    decoration: BoxDecoration(image: bg),
                  ),
                  // 渐变遮罩，保证文字可读
                  Positioned.fill(
                    child: IgnorePointer(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.black.withOpacity(.15),
                              Colors.black.withOpacity(.45),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  // 右上角 换背景按钮
                  Positioned(
                    top: 12,
                    right: 12,
                    child: FilledButton.icon(
                      style: FilledButton.styleFrom(
                        backgroundColor: Colors.black.withOpacity(.35),
                        foregroundColor: Colors.white,
                      ),
                      onPressed: _pickBackground,
                      icon: const Icon(Icons.image_outlined),
                      label: const Text('更换背景'),
                    ),
                  ),
                  // 左下角 头像 + 名字
                  Positioned(
                    left: 16,
                    bottom: 16,
                    right: 16,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        // 头像（可点击）
                        Stack(
                          children: [
                            InkWell(
                              borderRadius: BorderRadius.circular(56),
                              onTap: _pickAvatar,
                              child: CircleAvatar(
                                radius: 44,
                                backgroundImage: avatarProvider,
                              ),
                            ),
                            Positioned(
                              right: 0,
                              bottom: 0,
                              child: Container(
                                decoration: BoxDecoration(
                                  color: Colors.black.withOpacity(.65),
                                  shape: BoxShape.circle,
                                ),
                                padding: const EdgeInsets.all(4),
                                child: const Icon(Icons.photo_camera_outlined,
                                    size: 18, color: Colors.white),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(width: 14),
                        // 名称 + 编辑
                        Expanded(
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              Expanded(
                                child: GestureDetector(
                                  onTap: _editName,
                                  child: Text(
                                    _name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      fontSize: 24,
                                      fontWeight: FontWeight.w800,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 8),
                              IconButton(
                                onPressed: _editName,
                                style: IconButton.styleFrom(
                                  backgroundColor: Colors.white.withOpacity(.25),
                                ),
                                icon: const Icon(Icons.edit, color: Colors.white),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // 下方功能按钮区
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _SectionTitle('我的功能'),
                    const SizedBox(height: 12),
                    _ActionsGrid(
                      actions: [
                        _ActionItem(icon: Icons.groups_rounded, label: '朋友', onTap: () => _toast('朋友')),
                        _ActionItem(icon: Icons.account_circle_rounded, label: '账号', onTap: () => _toast('账号')),
                        _ActionItem(icon: Icons.settings_rounded, label: '设置', onTap: () => _toast('设置')),
                        _ActionItem(icon: Icons.photo_library_rounded, label: '相册', onTap: () => _toast('相册')),
                        _ActionItem(icon: Icons.emoji_events_rounded, label: '成就', onTap: () => _toast('成就')),
                        _ActionItem(icon: Icons.flag_rounded, label: '目标', onTap: () => _toast('目标')),
                        _ActionItem(icon: Icons.lock_rounded, label: '隐私', onTap: () => _toast('隐私')),
                        _ActionItem(icon: Icons.notifications_active_rounded, label: '通知', onTap: () => _toast('通知')),
                        _ActionItem(icon: Icons.sports_motorsports_rounded, label: '装备', onTap: () => _toast('装备')),
                        _ActionItem(icon: Icons.share_rounded, label: '分享', onTap: () => _toast('分享个人主页')),
                      ],
                    ),
                  ],
                ),
              ),
            ),

            // 你也可以在这里继续加「动态/帖子/相册预览」等区块
          ],
        ),
      ),
    );
  }
}

// ---------- 小部件 ----------

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style:
      Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
    );
  }
}

class _ActionItem {
  const _ActionItem({required this.icon, required this.label, required this.onTap});
  final IconData icon;
  final String label;
  final VoidCallback onTap;
}

class _ActionsGrid extends StatelessWidget {
  const _ActionsGrid({required this.actions});
  final List<_ActionItem> actions;

  @override
  Widget build(BuildContext context) {
    // 用 Wrap 实现自适应多列（更贴近移动端）
    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: actions
          .map(
            (a) => _ActionButton(
          icon: a.icon,
          label: a.label,
          onTap: a.onTap,
        ),
      )
          .toList(),
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final w = (MediaQuery.of(context).size.width - 16 * 2 - 12 * 3) / 4; // 4列
    return SizedBox(
      width: w,
      child: Material(
        color: Colors.white,
        elevation: 1.5,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(14),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 26, color: Theme.of(context).colorScheme.primary),
                const SizedBox(height: 8),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12, color: Colors.black87),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
