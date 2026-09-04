// Switch the MCP server on, and show what a client needs to connect.
//
// This opens a port on the local network and one of its tools plays sound
// through the car, so the screen says so plainly rather than burying it. Off
// unless switched on, and its token is revocable from that screen.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../mcp/mcp_server.dart';

class McpScreen extends StatelessWidget {
  const McpScreen({super.key, required this.server});
  final McpServer server;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: server,
      builder: (context, _) {
        final url = server.url;
        final token = server.token;
        return Scaffold(
          appBar: AppBar(title: const Text('Connect an assistant')),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                'Let an AI assistant read your measurements',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              const Text(
                'The phone can act as a measurement instrument an assistant '
                'talks to. It can list your tunes, read a measured curve with '
                'its noise floor, see the EQ this app recommends and why, and '
                'ask for a fresh measurement.\n\n'
                'The tuning decisions stay in the app. The assistant is there '
                'for a second opinion — to disagree with a band, or spot '
                'something the rules missed.',
              ),
              const SizedBox(height: 16),
              Card(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                child: const Padding(
                  padding: EdgeInsets.all(12),
                  child: Text(
                    'While this is on, anything on your network that has the '
                    'token can read your measurements and start a measurement, '
                    'which plays sound through the car. Turn it off when you '
                    'are done, and avoid leaving it on over public Wi-Fi.',
                  ),
                ),
              ),
              const SizedBox(height: 8),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Allow assistant connections'),
                subtitle: Text(server.running ? 'On' : 'Off'),
                value: server.running,
                onChanged: (v) => v ? server.start() : server.stop(),
              ),
              if (server.error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text('Could not start: ${server.error}',
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error)),
                ),
              if (server.running && url != null && token != null) ...[
                const Divider(height: 28),
                Text('Address', style: Theme.of(context).textTheme.labelLarge),
                SelectableText(url,
                    style: const TextStyle(fontFamily: 'monospace')),
                const SizedBox(height: 12),
                Text('Token', style: Theme.of(context).textTheme.labelLarge),
                SelectableText(token,
                    style: const TextStyle(fontFamily: 'monospace')),
                const SizedBox(height: 12),
                Wrap(spacing: 8, children: [
                  OutlinedButton.icon(
                    onPressed: () => _copy(context, url, 'Address copied'),
                    icon: const Icon(Icons.link, size: 18),
                    label: const Text('Copy address'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => _copy(context, token, 'Token copied'),
                    icon: const Icon(Icons.key, size: 18),
                    label: const Text('Copy token'),
                  ),
                  OutlinedButton.icon(
                    onPressed: () => _regenerate(context),
                    icon: const Icon(Icons.autorenew, size: 18),
                    label: const Text('New token'),
                  ),
                ]),
                const SizedBox(height: 16),
                Text('In your assistant',
                    style: Theme.of(context).textTheme.labelLarge),
                const SizedBox(height: 4),
                const Text(
                  'Add it as a remote MCP server at the address above, sending '
                  'the token as an Authorization header:',
                ),
                const SizedBox(height: 6),
                SelectableText(
                  'Authorization: Bearer $_tokenPlaceholder'
                      .replaceFirst(_tokenPlaceholder, token),
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
                const SizedBox(height: 12),
                const Text(
                  'The phone and the computer must be on the same network. The '
                  'token stays the same across restarts, so it only has to be '
                  'set up once — use "New token" to revoke it, which stops '
                  'anything still holding the old one.',
                ),
              ],
              if (server.running && url == null)
                const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: Text(
                      'Running, but no network address was found — check Wi-Fi.'),
                ),
            ],
          ),
        );
      },
    );
  }

  static const _tokenPlaceholder = '<token>';

  /// Revoking is a deliberate act with a consequence — whatever is configured
  /// elsewhere stops working — so it asks first.
  Future<void> _regenerate(BuildContext context) async {
    final ok = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Issue a new token?'),
            content: const Text(
                'The current token stops working at once. Anything already set '
                'up with it — an assistant on your computer, for instance — '
                'will need the new one pasted in.'),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Keep the current one')),
              TextButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: const Text('Issue a new token')),
            ],
          ),
        ) ??
        false;
    if (!ok || !context.mounted) return;
    await server.regenerateToken();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('New token issued. The old one no longer works.')));
  }

  void _copy(BuildContext context, String value, String message) {
    Clipboard.setData(ClipboardData(text: value));
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }
}
