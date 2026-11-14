// A disposable Docker stand-in for simulation isolation tests.
package main

import (
	"fmt"
	"os"
)

func main() {
	_ = os.WriteFile(os.Getenv("KF_TEST_DOCKER_MARKER"), []byte("called"), 0600)
	fmt.Println(`{"Name":"simulation-test"}`)
}
