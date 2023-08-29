package main

import (
	"fmt"
	"log"
	"os"
	"strings"
)

var problematicFile = "docs/modules/ROOT/pages/references/crds.adoc"

func main() {

	foundEntries := map[string]int{}

	file, err := os.ReadFile(problematicFile)
	if err != nil {
		log.Fatal(err)
	}

	fileString := string(file)

	splitted := strings.Split(fileString, "\n")

	for i, line := range splitted {
		if strings.HasPrefix(line, "[id=") {
			if _, ok := foundEntries[line]; !ok {
				foundEntries[line] = 1
			} else {
				// we work only on additional occurances

				// add with greater number
				foundEntries[line] = foundEntries[line] + 1
				// transform line
				splitted[i] = strings.ReplaceAll(line, "[id=\"", fmt.Sprintf("[id=\"%d-", foundEntries[line]))
			}
		}
	}

	os.WriteFile(problematicFile, []byte(strings.Join(splitted, "\n")), 0644)
}
