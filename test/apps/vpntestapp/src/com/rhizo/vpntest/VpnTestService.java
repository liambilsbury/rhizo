package com.rhizo.vpntest;

import android.content.Intent;
import android.net.VpnService;
import android.os.ParcelFileDescriptor;
import android.util.Log;

import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.nio.ByteBuffer;
import java.nio.channels.DatagramChannel;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;

// VpnService for the UDP relay test
public class VpnTestService extends VpnService {
    private static final String TAG = "RhizoVpnTest";
    private static final String TUN_ADDR = "10.7.0.2";
    private static final int TUN_PREFIX = 32;
    private static final String DNS_SERVER = "192.168.100.1";
    private static final int MTU = 1400;
    private static final int IP_PROTO_UDP = 17;

    public static volatile boolean sEstablished;

    private final Map<String, UdpFlow> flows = new ConcurrentHashMap<String, UdpFlow>();
    private final AtomicLong relayedCount = new AtomicLong();
    private final AtomicLong droppedCount = new AtomicLong();
    private final AtomicInteger ipId = new AtomicInteger();
    private final Object tunWriteLock = new Object();

    private ParcelFileDescriptor tunFd;
    private FileOutputStream tunOut;
    private volatile boolean running;
    private Thread relayThread;

    // set up the tunnel once
    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        if (tunFd == null) establishAndRelay();
        return START_NOT_STICKY;
    }

    // create the tunnel interface and start the relay thread
    private void establishAndRelay() {
        Builder builder = new Builder();
        builder.addAddress(TUN_ADDR, TUN_PREFIX);
        builder.addRoute("0.0.0.0", 0);
        builder.setMtu(MTU);
        builder.addDnsServer(DNS_SERVER);
        builder.setSession("RhizoVpnTest");

        ParcelFileDescriptor pfd;
        try {
            pfd = builder.establish();
        } catch (Exception e) {
            Log.e(TAG, "RHIZO_VPN_ESTABLISH_FAILED reason=" + e, e);
            stopSelf();
            return;
        }
        if (pfd == null) {
            Log.e(TAG, "RHIZO_VPN_ESTABLISH_FAILED reason=establish_returned_null");
            stopSelf();
            return;
        }

        tunFd = pfd;
        tunOut = new FileOutputStream(pfd.getFileDescriptor());
        sEstablished = true;
        Log.i(TAG, "RHIZO_VPN_ESTABLISHED fd=" + pfd.getFd() + " mtu=" + MTU + " addr=" + TUN_ADDR);

        running = true;
        relayThread = new Thread(new Runnable() {
            public void run() { relayLoop(); }
        }, "rhizo-vpn-relay");
        relayThread.start();
    }

    // read packets from the tunnel and hand each to the packet handler
    private void relayLoop() {
        FileInputStream in = new FileInputStream(tunFd.getFileDescriptor());
        byte[] buf = new byte[MTU + 64];
        while (running) {
            int len;
            try {
                len = in.read(buf);
            } catch (IOException e) {
                if (running) Log.e(TAG, "RHIZO_VPN_DROP proto=unknown reason=tun_read_failed:" + e, e);
                break;
            }
            if (len <= 0) continue;
            handlePacket(buf, len);
        }
    }

    // relay a UDP packet to its destination and drop other protocols
    private void handlePacket(byte[] buf, int len) {
        if (len < 20) {
            drop("unknown", "short_packet");
            return;
        }
        int version = (buf[0] & 0xFF) >> 4;
        if (version != 4) {
            drop("ipv6", "ipv6_unsupported_by_this_test_app");
            return;
        }
        int ihl = (buf[0] & 0x0F) * 4;
        if (ihl < 20) {
            drop("udp", "malformed_ip_header_length");
            return;
        }
        int protocol = buf[9] & 0xFF;
        if (protocol != IP_PROTO_UDP) {
            drop(String.valueOf(protocol), "only_udp_relayed_by_this_test_app");
            return;
        }
        if (len < ihl + 8) {
            drop("udp", "short_udp_header");
            return;
        }

        byte[] srcAddr = new byte[]{buf[12], buf[13], buf[14], buf[15]};
        byte[] dstAddr = new byte[]{buf[16], buf[17], buf[18], buf[19]};
        int udpOff = ihl;
        int srcPort = readShort(buf, udpOff);
        int dstPort = readShort(buf, udpOff + 2);
        int udpLen = readShort(buf, udpOff + 4);
        int payloadOff = udpOff + 8;
        int payloadLen = udpLen - 8;
        if (payloadLen < 0 || payloadOff + payloadLen > len) {
            drop("udp", "malformed_udp_length");
            return;
        }

        String key = ipToString(srcAddr) + ":" + srcPort + ">" + ipToString(dstAddr) + ":" + dstPort;
        UdpFlow flow = flows.get(key);
        if (flow == null) {
            flow = createFlow(key, srcAddr, srcPort, dstAddr, dstPort);
            if (flow == null) return;
        }

        try {
            flow.channel.write(ByteBuffer.wrap(buf, payloadOff, payloadLen));
        } catch (IOException e) {
            flows.remove(key);
            closeFlow(flow);
            drop("udp", "send_failed:" + e);
            return;
        }
        relayedCount.incrementAndGet();
        Log.i(TAG, "RHIZO_VPN_RELAY proto=udp src=" + ipToString(srcAddr) + " dst=" + ipToString(dstAddr)
                + " dport=" + dstPort + " bytes=" + payloadLen);
    }

    // open a protected UDP socket for a flow
    private UdpFlow createFlow(String key, byte[] srcAddr, int srcPort, byte[] dstAddr, int dstPort) {
        DatagramChannel channel;
        try {
            channel = DatagramChannel.open();
        } catch (IOException e) {
            drop("udp", "open_failed:" + e);
            return null;
        }
        if (!protect(channel.socket())) {
            drop("udp", "protect_failed");
            closeQuiet(channel);
            return null;
        }
        try {
            channel.connect(new InetSocketAddress(InetAddress.getByAddress(dstAddr), dstPort));
        } catch (IOException e) {
            drop("udp", "connect_failed:" + e);
            closeQuiet(channel);
            return null;
        }

        final UdpFlow flow = new UdpFlow(channel, srcAddr, srcPort, dstAddr, dstPort);
        flows.put(key, flow);
        flow.readerThread = new Thread(new Runnable() {
            public void run() { replyLoop(flow); }
        }, "rhizo-vpn-reply-" + dstPort);
        flow.readerThread.start();
        return flow;
    }

    // relay the flow's replies to the tunnel
    private void replyLoop(UdpFlow flow) {
        ByteBuffer buf = ByteBuffer.allocate(MTU);
        while (running) {
            buf.clear();
            int n;
            try {
                n = flow.channel.read(buf);
            } catch (IOException e) {
                if (running) drop("udp", "reply_read_failed:" + e);
                break;
            }
            if (n <= 0) continue;
            writeReply(flow, buf.array(), n);
        }
    }

    // write the payload to the tunnel as an IPv4 UDP packet
    private void writeReply(UdpFlow flow, byte[] payload, int payloadLen) {
        int udpLen = 8 + payloadLen;
        int totalLen = 20 + udpLen;
        byte[] packet = new byte[totalLen];

        packet[0] = 0x45;
        packet[2] = (byte) ((totalLen >> 8) & 0xFF);
        packet[3] = (byte) (totalLen & 0xFF);
        int id = ipId.incrementAndGet() & 0xFFFF;
        packet[4] = (byte) ((id >> 8) & 0xFF);
        packet[5] = (byte) (id & 0xFF);
        packet[8] = 64;
        packet[9] = (byte) IP_PROTO_UDP;
        System.arraycopy(flow.dstAddr, 0, packet, 12, 4);
        System.arraycopy(flow.srcAddr, 0, packet, 16, 4);
        int ipSum = foldChecksum(sumWords(packet, 0, 20));
        packet[10] = (byte) ((ipSum >> 8) & 0xFF);
        packet[11] = (byte) (ipSum & 0xFF);

        int udpOff = 20;
        packet[udpOff] = (byte) ((flow.dstPort >> 8) & 0xFF);
        packet[udpOff + 1] = (byte) (flow.dstPort & 0xFF);
        packet[udpOff + 2] = (byte) ((flow.srcPort >> 8) & 0xFF);
        packet[udpOff + 3] = (byte) (flow.srcPort & 0xFF);
        packet[udpOff + 4] = (byte) ((udpLen >> 8) & 0xFF);
        packet[udpOff + 5] = (byte) (udpLen & 0xFF);
        System.arraycopy(payload, 0, packet, udpOff + 8, payloadLen);

        long pseudoSum = sumWords(flow.dstAddr, 0, 4) + sumWords(flow.srcAddr, 0, 4) + IP_PROTO_UDP + udpLen;
        int udpSum = foldChecksum(pseudoSum + sumWords(packet, udpOff, udpLen));
        if (udpSum == 0) udpSum = 0xFFFF;
        packet[udpOff + 6] = (byte) ((udpSum >> 8) & 0xFF);
        packet[udpOff + 7] = (byte) (udpSum & 0xFF);

        try {
            synchronized (tunWriteLock) {
                tunOut.write(packet, 0, totalLen);
            }
        } catch (IOException e) {
            drop("udp", "tun_write_failed:" + e);
            return;
        }
        Log.i(TAG, "RHIZO_VPN_REPLY dst=" + ipToString(flow.srcAddr) + " sport=" + flow.dstPort + " bytes=" + payloadLen);
    }

    // log the revocation and stop the service
    @Override
    public void onRevoke() {
        drop("control", "vpn_revoked_by_system");
        stopSelf();
    }

    // stop the relay and close all flows and the tunnel
    @Override
    public void onDestroy() {
        running = false;
        sEstablished = false;
        for (UdpFlow flow : flows.values()) closeFlow(flow);
        flows.clear();
        if (relayThread != null) relayThread.interrupt();
        if (tunFd != null) {
            try {
                tunFd.close();
            } catch (IOException e) {
                Log.e(TAG, "RHIZO_VPN_DROP proto=control reason=tun_close_failed:" + e, e);
            }
            tunFd = null;
        }
        Log.i(TAG, "RHIZO_VPN_STOPPED relayed=" + relayedCount.get() + " dropped=" + droppedCount.get());
        super.onDestroy();
    }

    // count and log a dropped packet
    private void drop(String proto, String reason) {
        droppedCount.incrementAndGet();
        Log.i(TAG, "RHIZO_VPN_DROP proto=" + proto + " reason=" + reason);
    }

    // close the flow's channel and stop its reader thread
    private void closeFlow(UdpFlow flow) {
        closeQuiet(flow.channel);
        if (flow.readerThread != null) flow.readerThread.interrupt();
    }

    // close the channel and log a failure
    private void closeQuiet(DatagramChannel channel) {
        try {
            channel.close();
        } catch (IOException e) {
            Log.e(TAG, "RHIZO_VPN_DROP proto=control reason=channel_close_failed:" + e, e);
        }
    }

    // return the big-endian 16-bit value at the offset
    private static int readShort(byte[] buf, int off) {
        return ((buf[off] & 0xFF) << 8) | (buf[off + 1] & 0xFF);
    }

    // return the four address bytes as dotted decimal
    private static String ipToString(byte[] addr) {
        return (addr[0] & 0xFF) + "." + (addr[1] & 0xFF) + "." + (addr[2] & 0xFF) + "." + (addr[3] & 0xFF);
    }

    // return the sum of 16-bit words
    private static long sumWords(byte[] data, int offset, int length) {
        long sum = 0;
        int end = offset + length;
        int i = offset;
        while (i + 1 < end) {
            sum += ((data[i] & 0xFF) << 8) | (data[i + 1] & 0xFF);
            i += 2;
        }
        if (i < end) sum += (data[i] & 0xFF) << 8;
        return sum;
    }

    // fold carries into 16 bits and return the complemented checksum
    private static int foldChecksum(long sum) {
        while ((sum >> 16) != 0) sum = (sum & 0xFFFFL) + (sum >> 16);
        return (int) ((~sum) & 0xFFFFL);
    }

    // relayed UDP flow state
    private static class UdpFlow {
        final DatagramChannel channel;
        final byte[] srcAddr;
        final int srcPort;
        final byte[] dstAddr;
        final int dstPort;
        Thread readerThread;

        UdpFlow(DatagramChannel channel, byte[] srcAddr, int srcPort, byte[] dstAddr, int dstPort) {
            this.channel = channel;
            this.srcAddr = srcAddr;
            this.srcPort = srcPort;
            this.dstAddr = dstAddr;
            this.dstPort = dstPort;
        }
    }
}
