import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../common.dart';
import '../../common/formatter/id_formatter.dart';
import '../../models/peer_model.dart';
import '../../models/platform_model.dart';

const kComputersTabKey = '__computers__';

/// New-tab page of the remote window: every saved computer as a card, like
/// the main window's Recent grid. The peer-list events only reach the main
/// window, so this reads the peer configs directly.
class ComputersPage extends StatefulWidget {
  final void Function(String id) onOpen;

  const ComputersPage({Key? key, required this.onOpen}) : super(key: key);

  @override
  State<ComputersPage> createState() => _ComputersPageState();
}

class _ComputersPageState extends State<ComputersPage> {
  List<Peer> _peers = [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final s = await bind.mainLoadRecentPeersForAb(filter: '');
      if (s.isEmpty) return;
      final peers = (jsonDecode(s) as List<dynamic>)
          .whereType<Map<String, dynamic>>()
          .map(Peer.fromJson)
          .toList();
      if (mounted) setState(() => _peers = peers);
    } catch (e) {
      debugPrint('Computers tab: failed to load peers: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Theme.of(context).colorScheme.background,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Wrap(
          spacing: 12,
          runSpacing: 12,
          children: _peers.map(_card).toList(),
        ),
      ),
    );
  }

  Widget _card(Peer peer) {
    final name =
        '${peer.username}${peer.username.isNotEmpty && peer.hostname.isNotEmpty ? '@' : ''}${peer.hostname}';
    final title = peer.alias.isEmpty ? formatID(peer.id) : peer.alias;
    return SizedBox(
      width: 220,
      height: 140,
      child: Material(
        color: Theme.of(context).colorScheme.background,
        borderRadius: BorderRadius.circular(8),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => widget.onOpen(peer.id),
          child: Column(
            children: [
              Expanded(
                child: Container(
                  width: double.infinity,
                  color: str2color('${peer.id}${peer.platform}', 0x7f),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      getPlatformImage(peer.platform, size: 60),
                      Text(
                        name,
                        style: const TextStyle(
                            color: Colors.white70, fontSize: 12),
                        textAlign: TextAlign.center,
                        overflow: TextOverflow.ellipsis,
                      ).paddingSymmetric(horizontal: 4),
                    ],
                  ),
                ),
              ),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      title,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                ],
              ).paddingSymmetric(horizontal: 12, vertical: 8),
            ],
          ),
        ),
      ),
    );
  }
}
