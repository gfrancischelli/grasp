package cli

import (
	"fmt"
	"strconv"

	"github.com/spf13/cobra"

	"github.com/gfrancischelli/grasp/grasp-cli/internal/publish"
)

var publishCmd = &cobra.Command{
	Use:   "publish [pr-number]",
	Short: "Send the local comment threads to the pull request on GitHub",
	Long: `Posts each unpublished thread as a review comment, with its replies in the
body. A thread on a line the pull request's diff covers goes on that line;
one the diff does not show — or a comment on the base side — goes on the
file, with the function and line it was written on at the top. Threads
already published are skipped, so publishing again after writing three more
comments only sends those.

Without a number, publishes to the pull request the checked-out branch is
open on.`,
	Args: cobra.MaximumNArgs(1),
	RunE: func(cmd *cobra.Command, args []string) error {
		root, err := repoRoot()
		if err != nil {
			return err
		}
		number := 0
		if len(args) == 1 {
			if number, err = strconv.Atoi(args[0]); err != nil || number <= 0 {
				return fmt.Errorf("%s is not a pull request number", args[0])
			}
		} else if number, err = publish.CurrentPR(root); err != nil {
			return fmt.Errorf("%w: grasp publish N", err)
		}

		sum, err := publish.Run(root, number, func(s string) { logln("%s", s) })
		if err != nil {
			return err
		}
		logln("published %d, skipped %d already published, %d failed", sum.Published, sum.Skipped, sum.Failed)
		if sum.Failed > 0 {
			return fmt.Errorf("%d thread(s) failed", sum.Failed)
		}
		return nil
	},
}

func init() {
	rootCmd.AddCommand(publishCmd)
}
