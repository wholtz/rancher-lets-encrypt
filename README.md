# Rancher Let's Encrypt

## Purpose

Briefly starts up a container and load balancer on Rancher 2.x that will request a certificate from Let's Encrypt.
This was designed for use at [NERSC](https://nersc.gov/) on their SPIN cluster, but can probably be used on
other Rancher 2.x systems with slight modification.

## Usage

```
git clone https://github.com/wholtz/rancher-lets-encrypt
cd rancher-lets-encrypt
./get-cert.sh --namespace MY_NAMESPACE --project MY_PROJECT 
```

outputs are in  *.cert and *.key files.
