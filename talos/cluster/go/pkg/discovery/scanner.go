package discovery

import (
	"bufio"
	"context"
	"fmt"
	"net"
	"os"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/jdw/talos-bootstrap/pkg/types"
	"golang.org/x/crypto/ssh"
)

// Scanner handles ARP-based IP discovery across Proxmox nodes
type Scanner struct {
	sshUser   string
	sshConfig *ssh.ClientConfig
	nodeIPs   map[string]net.IP
}

// NewScanner creates a new discovery scanner
func NewScanner(sshUser string, nodeIPs map[string]net.IP) *Scanner {
	return &Scanner{
		sshUser: sshUser,
		sshConfig: &ssh.ClientConfig{
			User:            sshUser,
			Auth:            []ssh.AuthMethod{},          // Will add key auth
			HostKeyCallback: ssh.InsecureIgnoreHostKey(), // TODO: proper verification
			Timeout:         10 * time.Second,
		},
		nodeIPs: nodeIPs,
	}
}

// SetPrivateKey configures SSH key authentication
func (s *Scanner) SetPrivateKey(keyPath string) error {
	key, err := os.ReadFile(keyPath)
	if err != nil {
		return fmt.Errorf("read private key: %w", err)
	}

	signer, err := ssh.ParsePrivateKey(key)
	if err != nil {
		return fmt.Errorf("parse private key: %w", err)
	}

	s.sshConfig.Auth = []ssh.AuthMethod{
		ssh.PublicKeys(signer),
	}
	return nil
}

// DiscoverVMs scans all Proxmox nodes for VM configurations and ARP entries
// This replaces your discover_live_state() function
func (s *Scanner) DiscoverVMs(ctx context.Context, vmids []types.VMID) (map[types.VMID]*types.LiveNode, error) {
	results := make(map[types.VMID]*types.LiveNode)
	var mu sync.Mutex
	var wg sync.WaitGroup

	// Semaphore to limit concurrency
	sem := make(chan struct{}, 5)

	for _, vmid := range vmids {
		wg.Add(1)
		go func(id types.VMID) {
			defer wg.Done()

			sem <- struct{}{}
			defer func() { <-sem }()

			node, err := s.findVMNode(ctx, id)
			if err != nil {
				// VM might not exist yet, that's ok
				return
			}

			mac, err := s.getVMMAC(ctx, id, node)
			if err != nil {
				return
			}

			ip, err := s.findIPByMAC(ctx, mac)
			if err != nil {
				// IP not found yet, VM might still be booting
				mu.Lock()
				results[id] = &types.LiveNode{
					VMID:   id,
					MAC:    mac,
					Status: types.StatusNotFound,
				}
				mu.Unlock()
				return
			}

			mu.Lock()
			results[id] = &types.LiveNode{
				VMID:         id,
				IP:           ip,
				MAC:          mac,
				Status:       types.StatusDiscovered,
				DiscoveredAt: time.Now(),
			}
			mu.Unlock()
		}(vmid)
	}

	wg.Wait()
	return results, nil
}

// RediscoverIP handles the post-reboot IP change scenario
// This is your rediscover_ip_by_mac() but with proper timeouts
func (s *Scanner) RediscoverIP(ctx context.Context, vmid types.VMID, mac string) (net.IP, error) {
	// Aggressive ARP repopulation across all nodes
	if err := s.repopulateARP(ctx); err != nil {
		return nil, fmt.Errorf("repopulate ARP: %w", err)
	}

	// Try multiple times with backoff
	backoff := []time.Duration{1 * time.Second, 2 * time.Second, 5 * time.Second, 10 * time.Second}

	for _, delay := range backoff {
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-time.After(delay):
		}

		ip, err := s.findIPByMAC(ctx, mac)
		if err == nil {
			return ip, nil
		}
	}

	return nil, fmt.Errorf("IP not found for MAC %s after retries", mac)
}

// repopulateARP runs parallel ping sweeps on all Proxmox nodes
// This replaces your arp_repopulate_aggressive()
func (s *Scanner) repopulateARP(ctx context.Context) error {
	var wg sync.WaitGroup
	errChan := make(chan error, len(s.nodeIPs))

	for nodeName, nodeIP := range s.nodeIPs {
		wg.Add(1)
		go func(name string, ip net.IP) {
			defer wg.Done()

			if err := s.repopulateNode(ctx, name, ip); err != nil {
				errChan <- fmt.Errorf("node %s: %w", name, err)
			}
		}(nodeName, nodeIP)
	}

	wg.Wait()
	close(errChan)

	// Return first error if any
	for err := range errChan {
		return err
	}
	return nil
}

func (s *Scanner) repopulateNode(ctx context.Context, nodeName string, nodeIP net.IP) error {
	client, err := ssh.Dial("tcp", fmt.Sprintf("%s:22", nodeIP), s.sshConfig)
	if err != nil {
		return fmt.Errorf("ssh dial: %w", err)
	}
	defer client.Close()

	session, err := client.NewSession()
	if err != nil {
		return err
	}
	defer session.Close()

	// Extract subnet from node IP
	ipStr := nodeIP.String()
	lastDot := strings.LastIndex(ipStr, ".")
	if lastDot == -1 {
		return fmt.Errorf("invalid IP format")
	}
	subnet := ipStr[:lastDot]

	// Flush ARP and ping sweep subnet
	cmd := fmt.Sprintf("ip -s -s neigh flush all && seq 1 254 | xargs -P 100 -I{} ping -c 1 -W 1 %s.{} >/dev/null 2>&1 || true", subnet)

	if err := session.Run(cmd); err != nil {
		return fmt.Errorf("ARP repop command: %w", err)
	}

	return nil
}

// findIPByMAC scans ARP tables across all nodes for a MAC address
func (s *Scanner) findIPByMAC(ctx context.Context, mac string) (net.IP, error) {
	ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
	defer cancel()

	results := make(chan net.IP, len(s.nodeIPs))
	var wg sync.WaitGroup

	for nodeName, nodeIP := range s.nodeIPs {
		wg.Add(1)
		go func(name string, ip net.IP) {
			defer wg.Done()

			client, err := ssh.Dial("tcp", fmt.Sprintf("%s:22", ip), s.sshConfig)
			if err != nil {
				return
			}
			defer client.Close()

			session, err := client.NewSession()
			if err != nil {
				return
			}
			defer session.Close()

			output, err := session.Output("cat /proc/net/arp")
			if err != nil {
				return
			}

			foundIP := parseARPTable(string(output), mac)
			if foundIP != nil {
				select {
				case results <- foundIP:
				case <-ctx.Done():
				}
			}
		}(nodeName, nodeIP)
	}

	// Close results when all goroutines done
	go func() {
		wg.Wait()
		close(results)
	}()

	// Return first result
	select {
	case ip := <-results:
		return ip, nil
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}

// parseARPTable extracts IP for given MAC from /proc/net/arp output
func parseARPTable(output, targetMAC string) net.IP {
	scanner := bufio.NewScanner(strings.NewReader(output))
	for scanner.Scan() {
		line := scanner.Text()
		fields := strings.Fields(line)
		if len(fields) < 4 {
			continue
		}

		ip := fields[0]
		mac := strings.ToUpper(fields[3])

		// Skip incomplete entries
		if mac == "00:00:00:00:00:00" || mac == "INCOMPLETE" {
			continue
		}

		if mac == strings.ToUpper(targetMAC) {
			return net.ParseIP(ip)
		}
	}
	return nil
}

// findVMNode determines which Proxmox node hosts a VM
func (s *Scanner) findVMNode(ctx context.Context, vmid types.VMID) (string, error) {
	for nodeName, nodeIP := range s.nodeIPs {
		found, err := s.checkVMOnNode(vmid, nodeIP)
		if err != nil {
			continue
		}

		if found {
			return nodeName, nil
		}
	}

	return "", fmt.Errorf("VM %d not found on any node", vmid)
}

func (s *Scanner) checkVMOnNode(vmid types.VMID, nodeIP net.IP) (bool, error) {
	client, err := ssh.Dial("tcp", fmt.Sprintf("%s:22", nodeIP), s.sshConfig)
	if err != nil {
		return false, err
	}
	defer client.Close()

	session, err := client.NewSession()
	if err != nil {
		return false, err
	}
	defer session.Close()

	if err := session.Run(fmt.Sprintf("qm status %d", vmid)); err != nil {
		return false, err
	}
	return true, nil
}

// getVMMAC extracts MAC address from VM config
func (s *Scanner) getVMMAC(ctx context.Context, vmid types.VMID, node string) (string, error) {
	nodeIP, ok := s.nodeIPs[node]
	if !ok {
		return "", fmt.Errorf("unknown node: %s", node)
	}

	client, err := ssh.Dial("tcp", fmt.Sprintf("%s:22", nodeIP), s.sshConfig)
	if err != nil {
		return "", err
	}
	defer client.Close()

	session, err := client.NewSession()
	if err != nil {
		return "", err
	}
	defer session.Close()

	output, err := session.Output(fmt.Sprintf("qm config %d", vmid))
	if err != nil {
		return "", err
	}

	// Extract MAC from net0: virtio=XX:XX:XX:XX:XX:XX,bridge=vmbr0
	re := regexp.MustCompile(`net\d+:.*virtio=([0-9A-Fa-f:]+)`)
	matches := re.FindStringSubmatch(string(output))
	if len(matches) < 2 {
		return "", fmt.Errorf("no MAC found in VM config")
	}

	return strings.ToUpper(matches[1]), nil
}

// TestPort checks if a port is open on an IP
func TestPort(ip string, port int, timeout time.Duration) bool {
	conn, err := net.DialTimeout("tcp", fmt.Sprintf("%s:%d", ip, port), timeout)
	if err != nil {
		return false
	}
	conn.Close()
	return true
}
