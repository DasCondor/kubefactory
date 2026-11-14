package main

// LiveView: real web pages, rendered by the Chromium-based browser already
// installed on this machine (Edge or Chrome), driven headless over the
// DevTools protocol. Pages are streamed to the game as frames and take real
// mouse, wheel and keyboard input, so what is on the in-world screen is the
// application itself, not a picture of it.
//
// Trust boundary:
//   - every session runs in its own throw-away profile directory, deleted on
//     close: no cookies, logins or history are shared with the user's own
//     browser or between sessions;
//   - navigation is confined to the hosts the session was opened for; a
//     document request to any other host is refused and reported;
//   - TLS verification is left on (no certificate-error overrides);
//   - no JavaScript bridge is exposed to the page;
//   - the DevTools endpoint listens on loopback only, on a random port, for
//     the lifetime of the session.
//
// Nothing is bundled: if no Chromium-based browser is installed, LiveView
// reports that and the game offers to open the address in the default browser.

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"hash/fnv"
	"fmt"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"

	"github.com/chromedp/cdproto/fetch"
	"github.com/chromedp/cdproto/input"
	"github.com/chromedp/cdproto/network"
	"github.com/chromedp/cdproto/page"
	"github.com/chromedp/chromedp"
)

type browserSession struct {
	id      string
	ctx     context.Context
	cancel  context.CancelFunc
	profile string
	w, h    int64

	mu      sync.Mutex
	allowed map[string]bool
	minGap  time.Duration
	paused  bool
	good    string // the last page of the application itself, to return to after a refused jump
}

var (
	browsers   = map[string]*browserSession{}
	browsersMu sync.Mutex
	browserSeq int
)

func findBrowser() string {
	var c []string
	switch runtime.GOOS {
	case "windows":
		for _, base := range []string{os.Getenv("ProgramFiles(x86)"), os.Getenv("ProgramFiles"), os.Getenv("LOCALAPPDATA")} {
			if base != "" {
				c = append(c, filepath.Join(base, "Microsoft", "Edge", "Application", "msedge.exe"), filepath.Join(base, "Google", "Chrome", "Application", "chrome.exe"))
			}
		}
	case "darwin":
		c = []string{"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", "/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge"}
	default:
		for _, n := range []string{"google-chrome", "chromium", "chromium-browser", "microsoft-edge"} {
			if p, err := exec.LookPath(n); err == nil {
				c = append(c, p)
			}
		}
	}
	for _, p := range c {
		if st, err := os.Stat(p); err == nil && !st.IsDir() {
			return p
		}
	}
	return ""
}

func hostOf(raw string) string {
	u, err := url.Parse(raw)
	if err != nil {
		return ""
	}
	return strings.ToLower(u.Host)
}

func (b *browserSession) close() {
	b.cancel()
	if b.profile != "" {
		go func() { // the browser needs a moment to let go of its profile
			for i := 0; i < 20; i++ {
				if os.RemoveAll(b.profile) == nil {
					return
				}
				time.Sleep(250 * time.Millisecond)
			}
		}()
	}
}

func closeAllBrowsers() {
	browsersMu.Lock()
	list := browsers
	browsers = map[string]*browserSession{}
	browsersMu.Unlock()
	for _, b := range list {
		b.cancel()
		os.RemoveAll(b.profile)
	}
	if len(list) > 0 {
		time.Sleep(600 * time.Millisecond)
		for _, b := range list {
			os.RemoveAll(b.profile)
		}
	}
}

func getBrowser(id string) (*browserSession, error) {
	browsersMu.Lock()
	defer browsersMu.Unlock()
	b, ok := browsers[id]
	if !ok {
		return nil, fail("invalid", "that LiveView session is closed")
	}
	return b, nil
}

func (b *browserSession) do(actions ...chromedp.Action) error {
	ctx, cancel := context.WithTimeout(b.ctx, 20*time.Second)
	defer cancel()
	return chromedp.Run(ctx, actions...)
}

// pump captures the page at the session's frame rate and sends a frame only
// when the picture changed. (Edge's own screencast stream stays silent in
// headless mode, so frames are pulled rather than pushed.)
func (b *browserSession) pump() {
	var last uint64
	for {
		b.mu.Lock()
		gap, paused := b.minGap, b.paused
		b.mu.Unlock()
		select {
		case <-b.ctx.Done():
			return
		case <-time.After(gap):
		}
		if paused {
			continue
		}
		var buf []byte
		ctx, cancel := context.WithTimeout(b.ctx, 10*time.Second)
		err := chromedp.Run(ctx, chromedp.ActionFunc(func(c context.Context) error {
			var e error
			buf, e = page.CaptureScreenshot().WithFormat(page.CaptureScreenshotFormatJpeg).WithQuality(72).WithOptimizeForSpeed(true).Do(c)
			return e
		}))
		cancel()
		if err != nil || len(buf) == 0 {
			continue
		}
		h := fnv.New64a()
		h.Write(buf)
		if sum := h.Sum64(); sum != last {
			last = sum
			emit("frame", map[string]any{"sid": b.id, "jpeg": base64.StdEncoding.EncodeToString(buf)})
		}
	}
}

func navError(err error) *opError {
	m := err.Error()
	switch {
	case strings.Contains(m, "ERR_CONNECTION_REFUSED"), strings.Contains(m, "ERR_CONNECTION_RESET"), strings.Contains(m, "ERR_ADDRESS_UNREACHABLE"), strings.Contains(m, "ERR_NAME_NOT_RESOLVED"), strings.Contains(m, "ERR_EMPTY_RESPONSE"):
		return fail("unreachable", "nothing answered at that address")
	case strings.Contains(m, "ERR_UNSAFE_PORT"):
		return fail("invalid", "browsers refuse to open that port")
	case strings.Contains(m, "ERR_CERT"), strings.Contains(m, "ERR_SSL"):
		return fail("tls", "the site's certificate was not accepted")
	case strings.Contains(m, "ERR_BLOCKED_BY_CLIENT"):
		return fail("rbac", "that address is outside the hosts this display is allowed to show")
	case strings.Contains(m, "ERR_TIMED_OUT"), strings.Contains(m, "deadline exceeded"):
		return fail("timeout", "the page did not load in time")
	}
	return fail("other", "%s", strings.SplitN(m, "\n", 2)[0])
}

func registerBrowser() {
	ops["browser.find"] = func(json.RawMessage) (any, error) {
		p := findBrowser()
		return map[string]any{"found": p != "", "name": filepath.Base(p)}, nil
	}

	ops["browser.open"] = func(raw json.RawMessage) (any, error) {
		a, err := decode[struct {
			URL    string   `json:"url"`
			Width  int64    `json:"width"`
			Height int64    `json:"height"`
			FPS    int      `json:"fps"`
			Allow  []string `json:"allow"` // extra hosts this display may navigate to
		}](raw)
		if err != nil {
			return nil, err
		}
		u, perr := url.Parse(a.URL)
		if perr != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
			return nil, fail("invalid", "LiveView shows http and https addresses only")
		}
		exe := findBrowser()
		if exe == "" {
			return nil, fail("unsupported", "no Chromium-based browser (Edge or Chrome) is installed, so the page cannot be drawn in the world")
		}
		if a.Width < 320 || a.Width > 2560 {
			a.Width = 1280
		}
		if a.Height < 240 || a.Height > 1600 {
			a.Height = 720
		}
		if a.FPS <= 0 || a.FPS > 60 {
			a.FPS = 15
		}
		profile, err := os.MkdirTemp("", "kubefactory-liveview-")
		if err != nil {
			return nil, fail("other", "could not create a browser profile folder")
		}
		opts := append(chromedp.DefaultExecAllocatorOptions[:],
			chromedp.ExecPath(exe), chromedp.UserDataDir(profile), chromedp.WindowSize(int(a.Width), int(a.Height)),
			chromedp.Flag("headless", "new"), chromedp.Flag("hide-scrollbars", false), chromedp.Flag("mute-audio", true),
			chromedp.Flag("disable-extensions", true), chromedp.Flag("no-first-run", true), chromedp.Flag("no-default-browser-check", true),
			chromedp.Flag("disable-sync", true), chromedp.Flag("disable-background-networking", true))
		allocCtx, cancelAlloc := chromedp.NewExecAllocator(context.Background(), opts...)
		ctx, cancelCtx := chromedp.NewContext(allocCtx)
		b := &browserSession{ctx: ctx, profile: profile, w: a.Width, h: a.Height, allowed: map[string]bool{strings.ToLower(u.Host): true},
			minGap: time.Second / time.Duration(a.FPS), cancel: func() { cancelCtx(); cancelAlloc() }}
		for _, h := range a.Allow {
			b.allowed[strings.ToLower(h)] = true
		}
		browsersMu.Lock()
		browserSeq++
		b.id = fmt.Sprintf("b%d", browserSeq)
		browsersMu.Unlock()

		chromedp.ListenTarget(ctx, func(ev any) {
			switch e := ev.(type) {
			case *fetch.EventRequestPaused:
				h := hostOf(e.Request.URL)
				b.mu.Lock()
				ok := b.allowed[h] || strings.HasPrefix(e.Request.URL, "about:") || strings.HasPrefix(e.Request.URL, "data:") || strings.HasPrefix(e.Request.URL, "blob:")
				b.mu.Unlock()
				if ok {
					go chromedp.Run(ctx, fetch.ContinueRequest(e.RequestID))
				} else {
					go func() {
						chromedp.Run(ctx, fetch.FailRequest(e.RequestID, network.ErrorReasonBlockedByClient))
						// the refused jump leaves the tab on an error page: put the application back
						b.mu.Lock()
						back := b.good
						b.mu.Unlock()
						if back != "" && e.ResourceType == network.ResourceTypeDocument {
							time.Sleep(150 * time.Millisecond)
							b.do(chromedp.Navigate(back))
						}
					}()
					emit("blocked", map[string]any{"sid": b.id, "host": h})
				}
			case *page.EventFrameNavigated:
				if e.Frame != nil && e.Frame.ParentID == "" && (strings.HasPrefix(e.Frame.URL, "http://") || strings.HasPrefix(e.Frame.URL, "https://")) {
					b.mu.Lock()
					b.good = e.Frame.URL
					b.mu.Unlock()
					emit("nav", map[string]any{"sid": b.id, "url": e.Frame.URL})
				}
			}
		})

		// Start the browser on the session's own context. chromedp ties the
		// browser's life to the context of the first Run, so a short-lived
		// one here would take the browser down as soon as this call returned.
		if err := chromedp.Run(ctx); err != nil {
			b.close()
			return nil, fail("other", "the browser did not start: %s", strings.SplitN(err.Error(), "\n", 2)[0])
		}
		openCtx, cancelOpen := context.WithTimeout(ctx, 30*time.Second)
		defer cancelOpen()
		if err := chromedp.Run(openCtx,
			fetch.Enable().WithPatterns([]*fetch.RequestPattern{{URLPattern: "*", ResourceType: network.ResourceTypeDocument}}),
			chromedp.EmulateViewport(a.Width, a.Height)); err != nil {
			b.close()
			return nil, fail("other", "the browser did not start: %s", strings.SplitN(err.Error(), "\n", 2)[0])
		}
		resp, err := chromedp.RunResponse(openCtx, chromedp.Navigate(a.URL))
		if err != nil {
			b.close()
			return nil, navError(err)
		}
		status := int64(0)
		if resp != nil {
			status = resp.Status
		}
		var title string
		chromedp.Run(openCtx, chromedp.Title(&title))
		go b.pump()
		browsersMu.Lock()
		browsers[b.id] = b
		browsersMu.Unlock()
		return map[string]any{"sid": b.id, "status": status, "title": title, "width": a.Width, "height": a.Height, "browser": filepath.Base(exe)}, nil
	}

	ops["browser.close"] = func(raw json.RawMessage) (any, error) {
		a, _ := decode[struct{ Sid string }](raw)
		browsersMu.Lock()
		b := browsers[a.Sid]
		delete(browsers, a.Sid)
		browsersMu.Unlock()
		if b != nil {
			b.close()
		}
		return map[string]any{}, nil
	}

	// Frame rate and suspension: the game lowers the rate for distant
	// displays and pauses ones nobody can see.
	ops["browser.rate"] = func(raw json.RawMessage) (any, error) {
		a, err := decode[struct {
			Sid    string
			FPS    int
			Paused bool
		}](raw)
		if err != nil {
			return nil, err
		}
		b, err := getBrowser(a.Sid)
		if err != nil {
			return nil, err
		}
		if a.FPS <= 0 || a.FPS > 60 {
			a.FPS = 15
		}
		b.mu.Lock()
		b.paused, b.minGap = a.Paused, time.Second/time.Duration(a.FPS)
		b.mu.Unlock()
		return map[string]any{}, nil
	}

	ops["browser.navigate"] = func(raw json.RawMessage) (any, error) {
		a, err := decode[struct{ Sid, URL, Action string }](raw)
		if err != nil {
			return nil, err
		}
		b, err := getBrowser(a.Sid)
		if err != nil {
			return nil, err
		}
		switch a.Action {
		case "back":
			err = b.do(chromedp.NavigateBack())
		case "forward":
			err = b.do(chromedp.NavigateForward())
		case "reload":
			err = b.do(chromedp.Reload())
		default:
			h := hostOf(a.URL)
			b.mu.Lock()
			ok := b.allowed[h]
			b.mu.Unlock()
			if !ok {
				return nil, fail("rbac", "%s is outside the hosts this display is allowed to show", h)
			}
			err = b.do(chromedp.Navigate(a.URL))
		}
		if err != nil {
			return nil, navError(err)
		}
		return map[string]any{}, nil
	}

	// Input, in page pixels. kind: move | down | up | wheel | text | key.
	ops["browser.input"] = func(raw json.RawMessage) (any, error) {
		a, err := decode[struct {
			Sid, Kind, Text, Key, Code string
			X, Y, DX, DY               float64
			Button                     string
			VK                         int64
			Shift, Ctrl, Alt           bool
			Down                       bool
		}](raw)
		if err != nil {
			return nil, err
		}
		b, err := getBrowser(a.Sid)
		if err != nil {
			return nil, err
		}
		var mods input.Modifier
		if a.Alt {
			mods |= input.ModifierAlt
		}
		if a.Ctrl {
			mods |= input.ModifierCtrl
		}
		if a.Shift {
			mods |= input.ModifierShift
		}
		btn := input.Left
		if a.Button == "right" {
			btn = input.Right
		} else if a.Button == "middle" {
			btn = input.Middle
		}
		switch a.Kind {
		case "move":
			err = b.do(input.DispatchMouseEvent(input.MouseMoved, a.X, a.Y).WithModifiers(mods))
		case "down":
			err = b.do(input.DispatchMouseEvent(input.MousePressed, a.X, a.Y).WithButton(btn).WithClickCount(1).WithModifiers(mods))
		case "up":
			err = b.do(input.DispatchMouseEvent(input.MouseReleased, a.X, a.Y).WithButton(btn).WithClickCount(1).WithModifiers(mods))
		case "wheel":
			err = b.do(input.DispatchMouseEvent(input.MouseWheel, a.X, a.Y).WithDeltaX(a.DX).WithDeltaY(a.DY).WithModifiers(mods))
		case "text":
			err = b.do(input.InsertText(a.Text))
		case "key":
			t := input.KeyUp
			if a.Down {
				t = input.KeyRawDown
			}
			err = b.do(input.DispatchKeyEvent(t).WithKey(a.Key).WithCode(a.Code).WithWindowsVirtualKeyCode(a.VK).WithNativeVirtualKeyCode(a.VK).WithModifiers(mods))
		default:
			return nil, fail("invalid", "unknown input kind")
		}
		if err != nil {
			return nil, fail("other", "%s", strings.SplitN(err.Error(), "\n", 2)[0])
		}
		return map[string]any{}, nil
	}
}
