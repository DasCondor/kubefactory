//go:build windows

package main

// Tokens are protected with the Windows Data Protection API (DPAPI), the same
// per-user protection Windows uses for its own saved credentials: the sealed
// value can only be opened by this Windows account on this computer.

import (
	"encoding/base64"
	"unsafe"

	"golang.org/x/sys/windows"
)

func canSeal() bool { return true }

func blob(b []byte) *windows.DataBlob {
	if len(b) == 0 {
		return &windows.DataBlob{}
	}
	return &windows.DataBlob{Size: uint32(len(b)), Data: &b[0]}
}

func seal(secret string) (string, error) {
	var out windows.DataBlob
	if err := windows.CryptProtectData(blob([]byte(secret)), nil, nil, 0, nil, windows.CRYPTPROTECT_UI_FORBIDDEN, &out); err != nil {
		return "", err
	}
	defer windows.LocalFree(windows.Handle(unsafe.Pointer(out.Data)))
	return base64.StdEncoding.EncodeToString(unsafe.Slice(out.Data, out.Size)), nil
}

func unseal(sealed string) (string, error) {
	raw, err := base64.StdEncoding.DecodeString(sealed)
	if err != nil {
		return "", err
	}
	var out windows.DataBlob
	if err := windows.CryptUnprotectData(blob(raw), nil, nil, 0, nil, windows.CRYPTPROTECT_UI_FORBIDDEN, &out); err != nil {
		return "", err
	}
	defer windows.LocalFree(windows.Handle(unsafe.Pointer(out.Data)))
	return string(unsafe.Slice(out.Data, out.Size)), nil
}
