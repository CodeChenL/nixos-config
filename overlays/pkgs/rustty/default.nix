{ inputs, prev, ... }:

{
  rustty = inputs.rustty.packages.${prev.stdenv.hostPlatform.system}.rustty;
}
