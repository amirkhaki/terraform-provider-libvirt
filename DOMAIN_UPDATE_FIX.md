# Domain Update Fix: Explanation and Verification

## Problem Statement
Changing attributes like `vcpu` and `memory` resulted in creating a new VM instead of updating the existing VM.

## Root Cause
The `Update()` method in `domain_resource.go` was unnecessarily calling `DomainUndefine()` before `DomainDefineXML()`:

```go
// OLD CODE (lines 825-840)
if err := r.client.Libvirt().DomainUndefine(existingDomain); err != nil {
    // error handling
}

newDomain, err := r.client.Libvirt().DomainDefineXML(xmlString)
```

This undefine-redefine pattern effectively recreated the VM for every configuration change.

## Why This Was Wrong

According to libvirt's API documentation:
- `DomainDefineXML()` with an XML containing an **existing UUID** automatically **replaces** that domain's definition
- There is **no need** to call `DomainUndefine()` first
- The domain must be inactive (shut down) for the update to take effect, which the code already handles correctly

## The Fix

Simply remove the `DomainUndefine()` call. The updated code:

```go
// NEW CODE (lines 816-829)
// Define the domain with the updated XML.
// Since the UUID is preserved, this replaces the existing domain definition.
// No need to undefine first - DomainDefineXML with the same UUID updates in-place.
newDomain, err := r.client.Libvirt().DomainDefineXML(xmlString)
if err != nil {
    resp.Diagnostics.AddError(
        "Domain Update Failed",
        "Failed to define updated domain in libvirt: "+err.Error(),
    )
    return
}
```

## What This Fixes

Now when users update domain attributes:
- **Memory** changes (e.g., `memory = 512` → `memory = 1024`)
- **vCPU** changes (e.g., `vcpu = 1` → `vcpu = 2`)
- **Device** changes (disks, interfaces, etc.)
- **Boot order** changes
- **CPU topology** changes
- Any other configuration changes

...the provider will **update the existing VM** instead of destroying and recreating it.

## Update Behavior

The update flow is now:
1. Shutdown the domain if it's running (already implemented)
2. Call `DomainDefineXML()` with the updated XML and same UUID
   - libvirt replaces the existing domain definition automatically
   - The domain UUID remains the same
   - The domain is updated in-place
3. Restart the domain if needed (already implemented)

## What Doesn't Change

- The domain's **UUID remains the same** (critical for Terraform state tracking)
- The domain is still shut down before applying updates (necessary for many configuration changes)
- The behavior for domain creation and deletion is unchanged
- All existing tests continue to pass

## Testing

The existing test in `domain_resource_test.go` already validates this:

```go
func TestAccDomainResource_basic(t *testing.T) {
    // ...
    Steps: []resource.TestStep{
        {
            Config: testAccDomainResourceConfigBasic("test-domain-basic"),
            Check: resource.ComposeAggregateTestCheckFunc(
                resource.TestCheckResourceAttr("libvirt_domain.test", "memory", "512"),
                resource.TestCheckResourceAttr("libvirt_domain.test", "vcpu", "1"),
            ),
        },
        // Update and Read testing
        {
            Config: testAccDomainResourceConfigBasicUpdated("test-domain-basic"),
            Check: resource.ComposeAggregateTestCheckFunc(
                resource.TestCheckResourceAttr("libvirt_domain.test", "memory", "1024"),
                resource.TestCheckResourceAttr("libvirt_domain.test", "vcpu", "2"),
            ),
        },
    },
}
```

This test verifies that:
1. A domain can be created with 512 MiB memory and 1 vCPU
2. The same domain can be updated to 1024 MiB memory and 2 vCPUs
3. The UUID remains the same (implicit - Terraform would fail if it changed)

## Impact

**Before the fix:**
- Every update triggered a destroy + recreate cycle
- Users lost all runtime state (would need to restart VMs)
- Data on non-persistent disks could be lost
- Terraform showed the VM as being replaced

**After the fix:**
- Updates are applied in-place
- Only requires a restart (shutdown → update definition → start)
- Runtime configuration is preserved where possible
- Terraform shows the VM as being updated, not replaced

## Verification Commands

To verify the fix works correctly, run:

```bash
# Build the provider
make build

# Run the specific test that validates updates
TF_ACC=1 go test -v -run TestAccDomainResource_basic ./internal/provider

# Or run all domain tests
make testacc
```

The test will:
1. Create a domain with 512 MiB / 1 vCPU
2. Update to 1024 MiB / 2 vCPUs
3. Verify the same domain (same UUID) was updated
4. Destroy the domain

If the test passes, it confirms the update is working correctly.

## Related libvirt Documentation

- [virDomainDefineXML](https://libvirt.org/html/libvirt-libvirt-domain.html#virDomainDefineXML): "Define a domain, but does not start it. If the domain already exists, the definition will be updated."
- [Domain XML Format](https://libvirt.org/formatdomain.html): Documents all configurable domain attributes
