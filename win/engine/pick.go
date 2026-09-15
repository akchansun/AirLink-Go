package engine

func (n *Node) PickAndSend(owner uintptr) {
	paths := nativePickFiles(owner)
	if len(paths) == 0 {
		return
	}
	n.mu.Lock()
	ids := append([]string(nil), n.multiIDs...)
	picking := n.pickingMany
	n.mu.Unlock()
	if picking && len(ids) > 0 {
		n.SendToIDs(ids, paths)
		return
	}
	peer, ok := n.selectedPeer()
	if !ok {
		return
	}
	n.SendPaths(peer, paths)
}

func (n *Node) PickAndSendFolder(owner uintptr) {
	paths := nativePickFolder(owner)
	if len(paths) == 0 {
		return
	}
	n.mu.Lock()
	ids := append([]string(nil), n.multiIDs...)
	picking := n.pickingMany
	n.mu.Unlock()
	if picking && len(ids) > 0 {
		n.SendToIDs(ids, paths)
		return
	}
	peer, ok := n.selectedPeer()
	if !ok {
		return
	}
	n.SendPaths(peer, paths)
}
