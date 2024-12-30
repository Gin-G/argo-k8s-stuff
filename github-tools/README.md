# GitHub ARC notes

Serverside apply must be on for this to work properly

## Updating API Token secret

When the GitHub API token expires or needs to be changed the runners don't pick it up automatically. After updating the secret, by deleting the existing one and adding the new one, you need to run the following to get the listeners to utilize the new token

```
# List all AutoscalingRunnerSets in the arc-systems namespace
kubectl get autoscalingrunnersets -n arc-systems

# Delete specific AutoscalingRunnerSet
kubectl delete autoscalingrunnersets -n arc-systems <name>
```

After that the listeners should pick up the new secret and connect to the repo. 