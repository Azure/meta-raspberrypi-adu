# Delta Update Recipe Deprecation Notice

## ⚠️ Important Change

The `adu-delta-image.bb` recipe has been **deprecated** in this layer (`meta-raspberrypi-adu`) and moved to the samples layer.

## 📍 New Location

The active delta generation recipe is now maintained in:

```
meta-azure-device-update-samples/recipes-samples/delta-generation/adu-delta-image.bb
```

## 🤔 Why This Change?

**Organizational Clarity:**
- Delta generation is a **sample/demo feature** for testing and development
- It belongs in `meta-azure-device-update-samples` alongside other sample recipes
- `meta-raspberrypi-adu` should focus on **core production ADU functionality**

**Benefits:**
- ✅ Clearer separation between production and sample code
- ✅ Easier to understand which features are production-ready
- ✅ Unified location for all delta-related sample code
- ✅ Simpler maintenance with single source of truth

## 🔄 Migration Guide

If your build was using the recipe from `meta-raspberrypi-adu`:

1. **No action required** if `meta-azure-device-update-samples` is in your `bblayers.conf`
   - BitBake will automatically use the samples version
   - Both layers are typically included in standard configurations

2. **Verify your layer configuration:**
   ```bash
   cd ~/adu_yocto/out/build
   cat build/conf/bblayers.conf | grep -E "meta-azure-device-update-samples|meta-raspberrypi-adu"
   ```

3. **Check which version is being used:**
   ```bash
   bitbake-layers show-recipes adu-delta-image
   ```

## 📋 File Status

| File | Status | Purpose |
|------|--------|---------|
| `adu-delta-image.bb` | **Renamed** | Now `adu-delta-image.bb.DEPRECATED-SEE-META-AZURE-DEVICE-UPDATE-SAMPLES` |
| Deprecated file | Reference only | Kept temporarily for reference, will be removed in future |
| Active recipe | In samples layer | `meta-azure-device-update-samples/recipes-samples/delta-generation/adu-delta-image.bb` |

## 🗓️ Timeline

- **January 22, 2026**: Recipe deprecated and moved to samples layer
- **Future release**: Deprecated file will be completely removed from `meta-raspberrypi-adu`

## 📚 Related Documentation

For more information about delta updates:
- See `meta-azure-device-update-samples/recipes-samples/delta-generation/`
- Check ADU documentation for delta update workflows

## ❓ Questions?

If you have concerns about this change or need help with migration, please refer to the Azure Device Update documentation or raise an issue in the project repository.
