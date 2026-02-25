package crd

import (
	"context"
	"fmt"
	"time"

	"github.com/sirupsen/logrus"

	v1 "k8s.io/apiextensions-apiserver/pkg/apis/apiextensions/v1"
	"k8s.io/apiextensions-apiserver/pkg/client/clientset/clientset"
	"k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/rest"
)

// CheckAndInstallCRD checks whether the CRD is already defined in the cluster
// and, if not, installs it and waits for it to be available.
func CheckAndInstallCRD(ctx context.Context, config *rest.Config) error {
	clientset, err := clientset.NewForConfig(config)
	if err != nil {
		return err
	}

	crdManager := &v1Manager{clientset}

	if err := crdManager.ApplyCRD(ctx); err != nil {
		return err
	}

	logrus.Infof("%s CRD is installed. Checking availability...", crdManager.GetCRDName(ctx))
	if err := monitorCRDAvailability(ctx, crdManager); err != nil {
		return err
	}
	logrus.Infof("%s CRD is available", crdManager.GetCRDName(ctx))

	return nil
}

func monitorCRDAvailability(ctx context.Context, crdManager *v1Manager) error {
	ctx, cancel := context.WithTimeout(context.Background(), time.Second*30)
	defer cancel()

	for {
		ok, err := crdManager.CheckCRD(ctx)
		if err != nil {
			return err
		}
		if ok {
			return nil
		}

		select {
		case <-ctx.Done():
			return fmt.Errorf("%s CRD has not become available before timeout", crdManager.GetCRDName(ctx))
		case <-time.After(time.Second):
		}
	}
}

// ////////////// v1 CRD Manager /////////////////

var fluentdConfigCRD = v1.CustomResourceDefinition{
	ObjectMeta: metav1.ObjectMeta{
		Name: "fluentdconfigs.logs.vdp.vmware.com",
	},
	Spec: v1.CustomResourceDefinitionSpec{
		Group: "logs.vdp.vmware.com",
		Names: v1.CustomResourceDefinitionNames{
			Plural: "fluentdconfigs",
			Kind:   "FluentdConfig",
		},
		Scope: v1.NamespaceScoped,
		Versions: []v1.CustomResourceDefinitionVersion{
			{
				Name:    "v1beta1",
				Served:  true,
				Storage: true,
				Schema: &v1.CustomResourceValidation{
					OpenAPIV3Schema: &v1.JSONSchemaProps{
						Type: "object",
						Properties: map[string]v1.JSONSchemaProps{
							"spec": {
								Type: "object",
								Properties: map[string]v1.JSONSchemaProps{
									"fluentconf": {
										Type: "string",
									},
								},
							},
						},
					},
				},
			},
		},
	},
}

type v1Manager struct {
	clientset *clientset.Clientset
}

func (m *v1Manager) ApplyCRD(ctx context.Context) error {
	if _, err := m.clientset.ApiextensionsV1().CustomResourceDefinitions().Create(ctx, &fluentdConfigCRD, metav1.CreateOptions{}); err != nil && !errors.IsAlreadyExists(err) {
		return err
	}

	return nil
}

func (m *v1Manager) CheckCRD(ctx context.Context) (bool, error) {
	crd, err := m.clientset.ApiextensionsV1().CustomResourceDefinitions().Get(ctx, m.GetCRDName(ctx), metav1.GetOptions{})
	if err != nil {
		return false, err
	}

	for _, cond := range crd.Status.Conditions {
		if cond.Type == v1.Established && cond.Status == v1.ConditionTrue {
			return true, nil
		}
	}
	return false, nil
}

func (m *v1Manager) GetCRDName(ctx context.Context) string {
	return fluentdConfigCRD.ObjectMeta.Name
}
