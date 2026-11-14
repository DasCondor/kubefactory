//go:build !windows

package main

// No protected storage is wired up outside Windows yet, so a token is refused
// rather than written to disk in the clear. Providers that need no token still work.

import "errors"

func canSeal() bool { return false }

func seal(string) (string, error) { return "", errors.New("no protected storage on this system") }

func unseal(string) (string, error) { return "", errors.New("no protected storage on this system") }
