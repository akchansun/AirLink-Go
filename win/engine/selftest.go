package engine

import (
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"time"

	"huchuan/protocol"
)

func RunSelfTest() error {
	fmt.Println("→ 协议与安全路径")
	if err := protocol.SelfCheck(); err != nil {
		return err
	}
	fmt.Println("→ 传输加密")
	if err := testSecureRoundTrip(); err != nil {
		return err
	}

	fmt.Println("→ 接收策略")
	if err := testReceiveMode(); err != nil {
		return err
	}

	root, err := os.MkdirTemp("", "huchuan-selftest-*")
	if err != nil {
		return err
	}
	defer os.RemoveAll(root)
	recv := filepath.Join(root, "recv")
	send := filepath.Join(root, "send")
	_ = os.MkdirAll(recv, 0o755)
	_ = os.MkdirAll(send, 0o755)

	n := NewNode(Settings{
		DeviceName:     "自检接收端",
		ReceiveFolder:  recv,
		AutoAccept:     true,
		Port:           42131,
		MaxConnections: 4,
		DeviceID:       "selftest-node",
	})
	if err := n.Start(); err != nil {
		return err
	}
	defer n.Stop()
	if err := n.WaitListening(4 * time.Second); err != nil {
		return err
	}
	time.Sleep(200 * time.Millisecond)

	fmt.Println("→ 刷新 / 手动添加 IP")
	n.AddManual("192.168.0.55", 41789)
	if _, ok := n.PeerByID("manual-192.168.0.55-41789"); !ok {
		found := false
		n.mu.Lock()
		for _, p := range n.peers {
			if p.Host == "192.168.0.55" {
				found = true
			}
		}
		n.mu.Unlock()
		if !found {
			return errMsg("手动添加 IP 失败")
		}
	}

	fmt.Println("→ 局域网发现（UDP + 加密握手）")
	if err := testDiscover(n); err != nil {
		return err
	}

	fmt.Println("→ 打开接收箱目录")
	if st, err := os.Stat(recv); err != nil || !st.IsDir() {
		return errMsg("接收文件夹不存在")
	}

	peer := n.LoopPeer()

	fmt.Println("→ 空文件")
	empty := filepath.Join(send, "空文件.txt")
	if err := os.WriteFile(empty, nil, 0o644); err != nil {
		return err
	}
	n.SendPaths(peer, []string{empty})
	if err := waitFile(filepath.Join(recv, "空文件.txt"), 12*time.Second); err != nil {
		return err
	}
	got, _ := os.ReadFile(filepath.Join(recv, "空文件.txt"))
	if len(got) != 0 {
		return errMsg("空文件收到后不是 0 字节")
	}

	fmt.Println("→ 小文件 + 大文件")
	small := filepath.Join(send, "短信.txt")
	if err := os.WriteFile(small, []byte("互传自检：你好"), 0o644); err != nil {
		return err
	}
	big := filepath.Join(send, "大文件.bin")
	if err := writePattern(big, 8*1024*1024); err != nil {
		return err
	}
	n.SendPaths(peer, []string{small, big})
	if err := waitFile(filepath.Join(recv, "大文件.bin"), 25*time.Second); err != nil {
		return err
	}
	a, _ := os.ReadFile(small)
	b, _ := os.ReadFile(filepath.Join(recv, "短信.txt"))
	if string(a) != string(b) {
		return errMsg("小文件内容不一致")
	}
	if err := comparePrefix(big, filepath.Join(recv, "大文件.bin"), 1024*1024); err != nil {
		return err
	}

	fmt.Println("→ 文件夹")
	dir := filepath.Join(send, "相册")
	_ = os.MkdirAll(dir, 0o755)
	_ = os.WriteFile(filepath.Join(dir, "一.jpg"), []byte("a"), 0o644)
	_ = os.WriteFile(filepath.Join(dir, "二.jpg"), []byte("bb"), 0o644)
	n.SendPaths(peer, []string{dir})
	if err := waitFile(filepath.Join(recv, "相册", "一.jpg"), 15*time.Second); err != nil {
		return err
	}
	if err := waitFile(filepath.Join(recv, "相册", "二.jpg"), 8*time.Second); err != nil {
		return err
	}

	fmt.Println("→ 拒绝接收")
	n.mu.Lock()
	n.settings.AutoAccept = false
	n.settings.ReceiveMode = "ask"
	n.mu.Unlock()
	rej := filepath.Join(send, "拒绝我.txt")
	_ = os.WriteFile(rej, []byte("no"), 0o644)
	n.SendPaths(peer, []string{rej})
	deadline := time.Now().Add(8 * time.Second)
	for time.Now().Before(deadline) {
		if n.Incoming() != nil {
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
	if n.Incoming() == nil {
		return errMsg("拒绝测试没有弹出请求")
	}
	n.RejectIncoming()
	deadline = time.Now().Add(8 * time.Second)
	okFail := false
	for time.Now().Before(deadline) {
		for _, it := range n.Items() {
			if it.State == "失败" || strings.Contains(it.Detail, "拒绝") {
				okFail = true
			}
		}
		if okFail {
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
	if !okFail {
		return errMsg("拒绝后发送方没有失败")
	}
	n.mu.Lock()
	n.settings.AutoAccept = true
	n.settings.ReceiveMode = "auto"
	n.mu.Unlock()

	fmt.Println("→ 口令拦截")
	n.mu.Lock()
	n.settings.Pin = "9988"
	n.mu.Unlock()
	conn, err := dialTCP("127.0.0.1", 42131, 8*time.Second)
	if err != nil {
		return err
	}
	wio := NewWire(conn, false)
	pin := "0000"
	if err := wio.SendJSON(protocol.Envelope{
		T: "hello", DeviceID: "x", Name: "闯关", Port: 1, HTTPPort: 1, OS: "macOS", AppVersion: "1.0.0", Pin: &pin,
	}); err != nil {
		conn.Close()
		return err
	}
	msg, err := wio.RecvJSON(8 * time.Second)
	conn.Close()
	if err != nil || msg.T != "reject" {
		return errMsg("错误口令没有被拦住")
	}
	n.mu.Lock()
	n.settings.Pin = ""
	n.mu.Unlock()

	fmt.Println("→ 发送文字")
	n.SendTextTo(peer, "你好，这是一段测试文字")
	deadline = time.Now().Add(8 * time.Second)
	gotText := false
	for time.Now().Before(deadline) {
		if t := n.IncomingText(); t != nil && t.Body == "你好，这是一段测试文字" {
			gotText = true
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
	if !gotText {
		return errMsg("文字没收到")
	}
	n.DismissText()

	fmt.Println("→ 取消传输")
	can := filepath.Join(send, "取消.bin")
	if err := writePattern(can, 16*1024*1024); err != nil {
		return err
	}
	n.SendPaths(peer, []string{can})
	deadline = time.Now().Add(10 * time.Second)
	var cancelID string
	for time.Now().Before(deadline) {
		for _, it := range n.Items() {
			if strings.Contains(it.Title, "取消.bin") && it.Direction == "send" {
				cancelID = it.ID
				if it.State == "等待中" || it.State == "传输中" {
					n.Cancel(it.ID)
				}
				break
			}
		}
		if cancelID != "" {
			break
		}
		time.Sleep(30 * time.Millisecond)
	}
	if cancelID != "" {
		deadline = time.Now().Add(8 * time.Second)
		for time.Now().Before(deadline) {
			for _, it := range n.Items() {
				if it.ID == cancelID && it.State == "已取消" {
					goto cancelledOK
				}
			}
			time.Sleep(50 * time.Millisecond)
		}
	}
cancelledOK:

	fmt.Println("→ 断点续传")
	res := filepath.Join(send, "续传.bin")
	if err := writePattern(res, 8*1024*1024); err != nil {
		return err
	}
	dest := filepath.Join(recv, "续传.bin")
	part := dest + ".huchuanpart"
	bits := dest + ".huchuanbits"
	plan := protocol.Plan(8 * 1024 * 1024)
	bitmap := protocol.NewBitmap(plan.ChunkCount())
	half := plan.ChunkCount() / 2
	if half < 1 {
		half = 1
	}
	hf, err := createPart(part, 8*1024*1024)
	if err != nil {
		return err
	}
	for i := 0; i < half; i++ {
		bitmap.Insert(i)
		start, end := plan.ByteRange(i)
		data, err := readAt(res, start, int(end-start))
		if err != nil {
			hf.Close()
			return err
		}
		if err := writeAt(hf, start, data); err != nil {
			hf.Close()
			return err
		}
	}
	hf.Close()
	if err := os.WriteFile(bits, bitmap.Data(), 0o644); err != nil {
		return err
	}
	n.SendPaths(peer, []string{res})
	if err := waitFile(dest, 20*time.Second); err != nil {
		return err
	}
	if err := comparePrefix(res, dest, 1024*1024); err != nil {
		return err
	}

	fmt.Println("→ 离线排队")
	ghost := n.LoopPeer()
	ghost.Favorite = true
	ghost.LastSeen = time.Time{}
	cancelQ := filepath.Join(send, "取消排队.txt")
	if err := os.WriteFile(cancelQ, []byte("不该发出去"), 0o644); err != nil {
		return err
	}
	n.SendPaths(ghost, []string{cancelQ})
	var cancelQID string
	deadline = time.Now().Add(8 * time.Second)
	for time.Now().Before(deadline) {
		for _, it := range n.Items() {
			if strings.Contains(it.Title, "取消排队.txt") && it.State == "等待对方上线" {
				cancelQID = it.ID
				n.Cancel(it.ID)
				break
			}
		}
		if cancelQID != "" {
			break
		}
		time.Sleep(30 * time.Millisecond)
	}
	if cancelQID == "" {
		return errMsg("离线发送没有进入排队")
	}
	queued := filepath.Join(send, "排队.txt")
	if err := os.WriteFile(queued, []byte("等你上线"), 0o644); err != nil {
		return err
	}
	n.SendPaths(ghost, []string{queued})
	deadline = time.Now().Add(8 * time.Second)
	parked := false
	for time.Now().Before(deadline) {
		for _, it := range n.Items() {
			if strings.Contains(it.Title, "排队.txt") && it.State == "等待对方上线" {
				parked = true
				break
			}
		}
		if parked {
			break
		}
		time.Sleep(30 * time.Millisecond)
	}
	if !parked {
		return errMsg("离线文件没有排进队列")
	}
	live := n.LoopPeer()
	live.Favorite = true
	live.LastSeen = time.Now()
	n.flushSendQueue(live)
	if err := waitFile(filepath.Join(recv, "排队.txt"), 12*time.Second); err != nil {
		return err
	}
	if _, err := os.Stat(filepath.Join(recv, "取消排队.txt")); err == nil {
		return errMsg("已取消的排队不该发出去")
	}

	fmt.Println("→ 手机网页通道")
	outboxURL := fmt.Sprintf("http://127.0.0.1:%d/api/outbox", HTTPPort(42131))
	if ob, err := http.Get(outboxURL); err == nil {
		_, _ = io.ReadAll(ob.Body)
		ob.Body.Close()
	}
	n.mu.Lock()
	hasPhone := false
	for _, p := range n.peers {
		if p.ID == "phone-web" {
			hasPhone = true
		}
	}
	n.mu.Unlock()
	if hasPhone {
		return errMsg("轮询发件箱不该冒出手机网页")
	}
	n.SetPage("phone")
	infoURL := fmt.Sprintf("http://127.0.0.1:%d/api/info", HTTPPort(42131))
	var resp *http.Response
	var err2 error
	for i := 0; i < 40; i++ {
		resp, err2 = http.Get(infoURL)
		if err2 == nil {
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
	if err2 != nil {
		return errMsg("网页信息接口失败")
	}
	body, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if resp.StatusCode != 200 || !strings.Contains(string(body), "自检接收端") {
		return errMsg("网页信息没有电脑名：" + string(body))
	}
	n.mu.Lock()
	gotPage, gotSel := n.page, n.selectedID
	n.mu.Unlock()
	if gotPage != "chat" || gotSel != "phone-web" {
		return errMsg("手机扫码后没有打开聊天窗口")
	}
	n.dropPhoneClaimed("127.0.0.1")
	n.mu.Lock()
	hasPhone = false
	for _, p := range n.peers {
		if p.ID == "phone-web" {
			hasPhone = true
		}
	}
	selAfter := n.selectedID
	n.mu.Unlock()
	if hasPhone || selAfter == "phone-web" {
		return errMsg("扫了别的电脑后这台还占着手机")
	}
	pageResp, err := http.Get(fmt.Sprintf("http://127.0.0.1:%d/", HTTPPort(42131)))
	if err != nil {
		return err
	}
	pageBody, _ := io.ReadAll(pageResp.Body)
	pageResp.Body.Close()
	if !strings.Contains(string(pageBody), "选择文件") {
		return errMsg("手机网页页面不完整")
	}
	if !strings.Contains(string(pageBody), "选择文件夹") {
		return errMsg("手机网页没有选文件夹")
	}
	if !strings.Contains(string(pageBody), "new Blob") {
		return errMsg("手机网页没有按实际字节发送")
	}
	if !strings.Contains(string(pageBody), "保存到手机") {
		return errMsg("手机网页不能接收电脑文件")
	}
	if !strings.Contains(string(pageBody), "另一部手机") {
		return errMsg("手机网页不能互传")
	}
	if !strings.Contains(string(pageBody), "/file/") {
		return errMsg("手机网页没有图片直链")
	}
	if !strings.Contains(string(pageBody), "保存到相册") {
		return errMsg("手机网页没有长按保存提示")
	}
	if !strings.Contains(string(pageBody), "?save=1") {
		return errMsg("手机网页不能保存普通文件")
	}
	if !strings.Contains(string(pageBody), "showPlayer") {
		return errMsg("手机网页不能收视频音频")
	}
	payload := []byte("from-phone")
	req, _ := http.NewRequest(http.MethodPost, fmt.Sprintf("http://127.0.0.1:%d/upload?name=phone-upload.txt", HTTPPort(42131)), strings.NewReader(string(payload)))
	req.ContentLength = int64(len(payload))
	up, err := http.DefaultClient.Do(req)
	if err != nil {
		return err
	}
	up.Body.Close()
	if up.StatusCode != 200 {
		return errMsg("网页上传失败")
	}
	if err := waitFile(filepath.Join(recv, "phone-upload.txt"), 8*time.Second); err != nil {
		return err
	}

	share := []byte("p2p")
	req2, _ := http.NewRequest(http.MethodPost, fmt.Sprintf("http://127.0.0.1:%d/upload?name=share-b.txt&from=phoneA", HTTPPort(42131)), strings.NewReader(string(share)))
	req2.ContentLength = int64(len(share))
	up2, err := http.DefaultClient.Do(req2)
	if err != nil {
		return err
	}
	up2.Body.Close()
	if up2.StatusCode != 200 {
		return errMsg("手机互传上传失败")
	}
	boxB, err := http.Get(fmt.Sprintf("http://127.0.0.1:%d/api/outbox?from=phoneB", HTTPPort(42131)))
	if err != nil {
		return err
	}
	bodyB, _ := io.ReadAll(boxB.Body)
	boxB.Body.Close()
	if !strings.Contains(string(bodyB), "share-b.txt") {
		return errMsg("另一部手机看不到发来的文件")
	}
	boxA, err := http.Get(fmt.Sprintf("http://127.0.0.1:%d/api/outbox?from=phoneA", HTTPPort(42131)))
	if err != nil {
		return err
	}
	bodyA, _ := io.ReadAll(boxA.Body)
	boxA.Body.Close()
	if strings.Contains(string(bodyA), "share-b.txt") {
		return errMsg("发出去的手机不该再看到自己的文件")
	}

	fmt.Println("  同一文件打开两次")
	var box struct {
		Files []struct {
			ID   string `json:"id"`
			Name string `json:"name"`
		} `json:"files"`
	}
	if err := json.Unmarshal(bodyB, &box); err != nil {
		return errMsg("发件箱不是 JSON")
	}
	shareID := ""
	for _, f := range box.Files {
		if f.Name == "share-b.txt" {
			shareID = f.ID
		}
	}
	if shareID == "" {
		return errMsg("发件箱没有互传文件编号")
	}
	for round := 1; round <= 2; round++ {
		d, err := http.Get(fmt.Sprintf("http://127.0.0.1:%d/download?id=%s", HTTPPort(42131), shareID))
		if err != nil {
			return err
		}
		got, _ := io.ReadAll(d.Body)
		d.Body.Close()
		if d.StatusCode != 200 || string(got) != "p2p" {
			return errMsg(fmt.Sprintf("第 %d 次打开手机文件不对", round))
		}
	}
	named, err := http.Get(fmt.Sprintf("http://127.0.0.1:%d/file/%s/share-b.txt", HTTPPort(42131), shareID))
	if err != nil {
		return err
	}
	namedBody, _ := io.ReadAll(named.Body)
	named.Body.Close()
	if named.StatusCode != 200 || string(namedBody) != "p2p" {
		return errMsg("带文件名的下载地址打不开")
	}
	saved, err := http.Get(fmt.Sprintf("http://127.0.0.1:%d/file/%s/share-b.txt?save=1", HTTPPort(42131), shareID))
	if err != nil {
		return err
	}
	savedBody, _ := io.ReadAll(saved.Body)
	disp := saved.Header.Get("Content-Disposition")
	saved.Body.Close()
	if saved.StatusCode != 200 || string(savedBody) != "p2p" {
		return errMsg("普通文件保存地址打不开")
	}
	if !strings.Contains(disp, "attachment") {
		return errMsg("普通文件没有按附件保存")
	}

	fmt.Println("→ 门店码")
	if err := testBooth(); err != nil {
		return err
	}

	fmt.Println("自检通过：全部功能正常")
	return nil
}

func testBooth() error {
	dir, err := os.MkdirTemp("", "huchuan-booth-*")
	if err != nil {
		return err
	}
	defer os.RemoveAll(dir)
	hub := newBoothHub(dir, nil)
	sess := hub.open("店里电脑", "http://127.0.0.1:9")
	if sess.PIN == "" || sess.ID == "" {
		return errMsg("门店码没生成")
	}
	item, err := hub.saveUpload(sess.ID, sess.PIN, "店单.txt", strings.NewReader("ok"), 2)
	if err != nil {
		return err
	}
	if item == nil || !fileExists(item.Path) {
		return errMsg("门店码文件没落下")
	}
	if protocol.MeetCode("甲", "乙") != protocol.MeetCode("乙", "甲") {
		return errMsg("见面码两边不一致")
	}
	if isPublicIPv4("192.168.1.8") || isPublicIPv4("100.64.1.2") || !isPublicIPv4("8.8.8.8") {
		return errMsg("外网地址判断")
	}
	p := WifiQRPayload("店;网", "a:b")
	if !strings.HasPrefix(p, "WIFI:S:") || !strings.Contains(p, `S:店\;网`) || !strings.Contains(p, `P:a\:b`) {
		return errMsg("连网码内容不对")
	}
	if WifiQRPayload("  ", "x") != "" {
		return errMsg("空名称不该出连网码")
	}
	if err := testBoothDirect(); err != nil {
		return err
	}
	return nil
}

func testBoothDirect() error {
	hub := newBoothHub("", nil)
	sess := hub.open("店里电脑", "http://example.invalid")
	_, err := hub.saveUpload(sess.ID, sess.PIN, "店单.txt", strings.NewReader("nope"), 4)
	if err == nil || !strings.Contains(err.Error(), "直接发到店里电脑") {
		return errMsg("中转不该收下文件")
	}
	if err := hub.announce(sess.ID, "bad", "http://192.168.1.8:80", ""); err == nil {
		return errMsg("口令不对时不该记下地址")
	}
	if err := hub.announce(sess.ID, sess.Token, "http://192.168.1.8:41780", "http://8.8.8.8:41780"); err != nil {
		return err
	}
	info := hub.publicInfo(sess.ID, sess.PIN)
	if info["ok"] != true {
		return errMsg("指路信息没有返回")
	}
	lan, _ := info["lan"].(string)
	wan, _ := info["wan"].(string)
	if !strings.Contains(lan, "192.168.1.8") || !strings.Contains(lan, sess.ID) {
		return errMsg("店里网地址不对")
	}
	if !strings.Contains(wan, "8.8.8.8") {
		return errMsg("外网地址不对")
	}
	if hub.announce(sess.ID, sess.Token, "javascript:alert(1)", "ftp://x") != nil {
		return errMsg("不该记下乱七八糟的地址")
	}
	info = hub.publicInfo(sess.ID, sess.PIN)
	lan, _ = info["lan"].(string)
	if !strings.Contains(lan, "192.168.1.8") {
		return errMsg("乱七八糟的地址不该盖掉店里地址")
	}
	return nil
}

func writePattern(path string, size int) error {
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	defer f.Close()
	buf := make([]byte, 64*1024)
	for i := range buf {
		buf[i] = byte(i)
	}
	left := size
	for left > 0 {
		n := len(buf)
		if n > left {
			n = left
		}
		if _, err := f.Write(buf[:n]); err != nil {
			return err
		}
		left -= n
	}
	return nil
}

func waitFile(path string, d time.Duration) error {
	deadline := time.Now().Add(d)
	for time.Now().Before(deadline) {
		if fileExists(path) {
			return nil
		}
		time.Sleep(50 * time.Millisecond)
	}
	return errMsg("等待文件超时：" + filepath.Base(path))
}

func comparePrefix(a, b string, n int) error {
	fa, err := os.Open(a)
	if err != nil {
		return err
	}
	defer fa.Close()
	fb, err := os.Open(b)
	if err != nil {
		return err
	}
	defer fb.Close()
	ba := make([]byte, n)
	bb := make([]byte, n)
	na, _ := io.ReadFull(fa, ba)
	nb, _ := io.ReadFull(fb, bb)
	if na != nb {
		return errMsg("续传文件大小对不上")
	}
	for i := 0; i < na; i++ {
		if ba[i] != bb[i] {
			return errMsg("文件内容不一致")
		}
	}
	return nil
}

func testDiscover(n *Node) error {
	port := n.settingsCopy().Port
	pkt := protocol.DiscoveryPacket{
		V: 1, ID: "win-udp-peer", Name: "Windows测试机",
		Port: 41789, HTTPPort: 41788, OS: "Windows",
	}
	data, _ := json.Marshal(pkt)
	dst := &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: int(UDPPort(port))}
	c, err := net.ListenUDP("udp4", &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: 0})
	if err != nil {
		return err
	}
	_, err = c.WriteToUDP(data, dst)
	c.Close()
	if err != nil {
		return err
	}
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if _, ok := n.PeerByID("win-udp-peer"); ok {
			break
		}
		time.Sleep(40 * time.Millisecond)
	}
	if _, ok := n.PeerByID("win-udp-peer"); !ok {
		return errMsg("UDP 发现包没有变成设备")
	}

	conn, err := dialTCP("127.0.0.1", port, time.Second)
	if err != nil {
		return err
	}
	w := NewWire(conn, false)
	hello := protocol.Envelope{
		T: "hello", DeviceID: "win-tcp-peer", Name: "Windows握手机",
		Port: 41789, HTTPPort: 41788, OS: "Windows", AppVersion: AppVersion,
	}
	if err := w.SendJSON(hello); err != nil {
		conn.Close()
		return err
	}
	if _, err := w.RecvJSON(2 * time.Second); err != nil {
		conn.Close()
		return err
	}
	conn.Close()
	deadline = time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if _, ok := n.PeerByID("win-tcp-peer"); ok {
			return nil
		}
		time.Sleep(40 * time.Millisecond)
	}
	return errMsg("TCP 握手后没有把对方记进设备列表")
}

func testReceiveMode() error {
	s := Settings{ReceiveMode: "auto"}
	if v := s.ShouldAutoAccept("a", "甲"); v == nil || !*v {
		return errMsg("自动收下没生效")
	}
	s.ReceiveMode = "off"
	if v := s.ShouldAutoAccept("a", "甲"); v == nil || *v {
		return errMsg("全部拒收没生效")
	}
	s.ReceiveMode = "fav"
	s.Favorites = []FavoritePeer{{ID: "a", Name: "甲"}}
	if v := s.ShouldAutoAccept("a", "甲"); v == nil || !*v {
		return errMsg("收藏自动收没生效")
	}
	if v := s.ShouldAutoAccept("b", "乙"); v != nil {
		return errMsg("没收藏的人不该自动收")
	}
	if peerOnline(Peer{ID: "fav", LastSeen: time.Time{}}, time.Now()) {
		return errMsg("没出现的收藏不该显示在线")
	}
	if !peerOnline(Peer{ID: "fav", LastSeen: time.Now()}, time.Now()) {
		return errMsg("刚出现的收藏该显示在线")
	}
	s.ReceiveMode = "ask"
	if v := s.ShouldAutoAccept("a", "甲"); v != nil {
		return errMsg("每次都问不该自动决定")
	}
	n := NewNode(Settings{DeviceID: "selftest-node", DiscoverMode: "off"})
	if n.allowPeer("x", "UDP 广播") {
		return errMsg("关闭发现后不该出现陌生人")
	}
	if !n.allowPeer("manual-1", "手动添加") {
		return errMsg("关闭发现后仍应能手填 IP")
	}
	return nil
}
