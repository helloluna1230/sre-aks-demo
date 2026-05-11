[CmdletBinding()]
param()

Write-Host @"

╔══════════════════════════════════════════════════════════════════════════════╗
║                    Azure SRE Agent Demo Lab                                  ║
╠══════════════════════════════════════════════════════════════════════════════╣
║  Commands:                                                                   ║
║    az login --use-device-code                 - Login to Azure               ║
║    .\scripts\deploy.ps1 -Location eastus2 -Yes - Deploy infrastructure       ║
║    .\scripts\destroy.ps1 -ResourceGroupName <rg> - Tear down infrastructure ║
║    .\scripts\menu.ps1                       - Show this help menu           ║
║                                                                              ║
║  Kubernetes commands (namespace: pets):                                       ║
║    kubectl get pods -n pets                   - Get pods                     ║
║    kubectl get svc -n pets                    - Get services                 ║
║    kubectl get deployments -n pets            - Get deployments              ║
║                                                                              ║
║  Break scenarios:                                                            ║
║    kubectl apply -f k8s/scenarios/oom-killed.yaml                            ║
║    kubectl apply -f k8s/scenarios/crash-loop.yaml                            ║
║    kubectl apply -f k8s/scenarios/image-pull-backoff.yaml                    ║
║    kubectl apply -f k8s/scenarios/high-cpu.yaml                              ║
║    kubectl apply -f k8s/scenarios/pending-pods.yaml                          ║
║    kubectl apply -f k8s/scenarios/probe-failure.yaml                         ║
║    kubectl apply -f k8s/scenarios/network-block.yaml                         ║
║    kubectl apply -f k8s/scenarios/missing-config.yaml                        ║
║    kubectl apply -f k8s/scenarios/mongodb-down.yaml                          ║
║    kubectl apply -f k8s/scenarios/service-mismatch.yaml                      ║
║                                                                              ║
║  Fix commands:                                                               ║
║    kubectl apply -f k8s/base/application.yaml - Restore healthy baseline      ║
║    kubectl delete networkpolicy deny-order-service -n pets                   ║
║    kubectl delete deployment cpu-stress-test resource-hog unhealthy-service ` ║
║      misconfigured-service -n pets                                           ║
║                                                                              ║
║  Dev container shortcuts:                                                     ║
║    menu, kgp, kgs, kgd, break-oom, break-crash, fix-all, site                ║
║                                                                              ║
║  Documentation: docs/                                                        ║
╚══════════════════════════════════════════════════════════════════════════════╝

"@ -ForegroundColor Cyan