package main

import (
	"flag"
	"log"
	"net"
	"os"
	"os/signal"
	"sync"
	"syscall"
	"time"
)

var (
	bindAddr       = flag.String("bind", ":5060", "Address to bind the SIP proxy to")
	livekitSIPAddr = flag.String("target", "12uujhkwedv.sip.livekit.cloud:5060", "LiveKit SIP server address")
	redisAddr      = flag.String("redis", "", "Existing Redis address if using LiveKit server")
)

func main() {
	flag.Parse()

	// Check for environment variables, with flags taking precedence
	if envBindAddr := os.Getenv("BIND_ADDR"); envBindAddr != "" && !flag.Lookup("bind").Changed {
		*bindAddr = envBindAddr
	}
	
	if envLivekitSIPAddr := os.Getenv("LIVEKIT_SIP_ADDR"); envLivekitSIPAddr != "" && !flag.Lookup("target").Changed {
		*livekitSIPAddr = envLivekitSIPAddr
	}
	
	if envRedisAddr := os.Getenv("REDIS_ADDR"); envRedisAddr != "" && !flag.Lookup("redis").Changed {
		*redisAddr = envRedisAddr
	}

	log.Printf("Starting SIP proxy on %s -> %s", *bindAddr, *livekitSIPAddr)
	if *redisAddr != "" {
		log.Printf("Using Redis at %s", *redisAddr)
	}
	
	// Create UDP listening socket for SIP
	udpAddr, err := net.ResolveUDPAddr("udp", *bindAddr)
	if err != nil {
		log.Fatalf("Failed to resolve bind address: %v", err)
	}
	
	listener, err := net.ListenUDP("udp", udpAddr)
	if err != nil {
		log.Fatalf("Failed to bind to %s: %v", *bindAddr, err)
	}
	defer listener.Close()
	
	// Create TCP listening socket for SIP
	tcpAddr, err := net.ResolveTCPAddr("tcp", *bindAddr)
	if err != nil {
		log.Fatalf("Failed to resolve TCP bind address: %v", err)
	}
	
	tcpListener, err := net.ListenTCP("tcp", tcpAddr)
	if err != nil {
		log.Fatalf("Failed to bind TCP to %s: %v", *bindAddr, err)
	}
	defer tcpListener.Close()
	
	// Create a proxy handler
	proxy := NewSIPProxy(*livekitSIPAddr)
	
	// Start the UDP proxy
	go proxy.StartUDP(listener)
	
	// Start the TCP proxy
	go proxy.StartTCP(tcpListener)
	
	// Wait for termination signal
	sigChan := make(chan os.Signal, 1)
	signal.Notify(sigChan, syscall.SIGINT, syscall.SIGTERM)
	<-sigChan
	
	log.Println("Shutting down SIP proxy")
}

// Session represents a SIP session
type Session struct {
	ClientAddr net.Addr
	ServerConn net.Conn
	LastActive time.Time
	mutex      sync.Mutex
}

// SIPProxy handles the actual proxying of SIP traffic
type SIPProxy struct {
	targetAddr string
	sessions   map[string]*Session
	sessionsMu sync.RWMutex
}

// NewSIPProxy creates a new SIP proxy
func NewSIPProxy(targetAddr string) *SIPProxy {
	return &SIPProxy{
		targetAddr: targetAddr,
		sessions:   make(map[string]*Session),
	}
}

// StartUDP begins proxying SIP traffic over UDP
func (p *SIPProxy) StartUDP(listener *net.UDPConn) {
	targetAddr, err := net.ResolveUDPAddr("udp", p.targetAddr)
	if err != nil {
		log.Fatalf("Failed to resolve target address: %v", err)
	}
	
	buffer := make([]byte, 8192) // Larger buffer for SIP messages
	
	for {
		n, addr, err := listener.ReadFromUDP(buffer)
		if err != nil {
			log.Printf("Error reading from UDP: %v", err)
			continue
		}
		
		log.Printf("Received %d bytes from %s", n, addr.String())
		
		// Get or create session
		sessionKey := addr.String()
		p.sessionsMu.RLock()
		session, exists := p.sessions[sessionKey]
		p.sessionsMu.RUnlock()
		
		if !exists {
			// Create a new UDP connection to the target
			serverConn, err := net.DialUDP("udp", nil, targetAddr)
			if err != nil {
				log.Printf("Failed to connect to target: %v", err)
				continue
			}
			
			session = &Session{
				ClientAddr: addr,
				ServerConn: serverConn,
				LastActive: time.Now(),
			}
			
			p.sessionsMu.Lock()
			p.sessions[sessionKey] = session
			p.sessionsMu.Unlock()
			
			// Start a goroutine to read responses from the server
			go p.handleServerResponses(session, listener)
		}
		
		// Update last active time
		session.mutex.Lock()
		session.LastActive = time.Now()
		session.mutex.Unlock()
		
		// Forward client request to server
		_, err = session.ServerConn.Write(buffer[:n])
		if err != nil {
			log.Printf("Failed to forward to target: %v", err)
			continue
		}
	}
}

// StartTCP begins proxying SIP traffic over TCP
func (p *SIPProxy) StartTCP(listener *net.TCPListener) {
	for {
		clientConn, err := listener.Accept()
		if err != nil {
			log.Printf("Error accepting TCP connection: %v", err)
			continue
		}
		
		// Connect to target server
		serverConn, err := net.Dial("tcp", p.targetAddr)
		if err != nil {
			log.Printf("Failed to connect to target server: %v", err)
			clientConn.Close()
			continue
		}
		
		// Handle the TCP connection bidirectionally
		go func() {
			defer clientConn.Close()
			defer serverConn.Close()
			
			// Client to server
			go func() {
				buffer := make([]byte, 8192)
				for {
					n, err := clientConn.Read(buffer)
					if err != nil {
						return
					}
					
					_, err = serverConn.Write(buffer[:n])
					if err != nil {
						return
					}
				}
			}()
			
			// Server to client
			buffer := make([]byte, 8192)
			for {
				n, err := serverConn.Read(buffer)
				if err != nil {
					return
				}
				
				_, err = clientConn.Write(buffer[:n])
				if err != nil {
					return
				}
			}
		}()
	}
}

// handleServerResponses reads responses from the server and forwards them to the client
func (p *SIPProxy) handleServerResponses(session *Session, listener *net.UDPConn) {
	buffer := make([]byte, 8192)
	
	for {
		n, err := session.ServerConn.Read(buffer)
		if err != nil {
			// Clean up session on error
			p.sessionsMu.Lock()
			delete(p.sessions, session.ClientAddr.String())
			p.sessionsMu.Unlock()
			
			session.ServerConn.Close()
			return
		}
		
		// Update last active time
		session.mutex.Lock()
		session.LastActive = time.Now()
		session.mutex.Unlock()
		
		// Forward server response to client
		_, err = listener.WriteTo(buffer[:n], session.ClientAddr)
		if err != nil {
			log.Printf("Error forwarding response to client: %v", err)
		}
	}
} 